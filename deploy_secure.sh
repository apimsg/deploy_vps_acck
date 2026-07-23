#!/bin/bash

# ================= 1. 基础环境检查 =================
echo "🚀 正在检查系统环境..."
if ! command -v python3 &> /dev/null; then
    echo "❌ 未检测到 Python3，正在尝试安装..."
    apt update && apt install -y python3-pip python3-venv git
else
    echo "✅ Python3 已安装"
fi

# ================= 2. 创建工作目录 =================
APP_DIR="vps_monitor_secure"
if [ ! -d "$APP_DIR" ]; then
    mkdir $APP_DIR
    echo "📂 已创建目录: $APP_DIR"
fi
cd $APP_DIR

# ================= 3. 创建虚拟环境 =================
if [ ! -d "venv" ]; then
    echo "🐍 正在创建 Python 虚拟环境..."
    python3 -m venv venv
fi
source venv/bin/activate

# ================= 4. 安装依赖 =================
echo "📦 正在安装依赖库..."
pip install --upgrade pip
pip install gradio requests pandas apscheduler aiogram aiohttp openpyxl

# ================= 5. 生成代码文件 (已移除默认值，改为后台配置) =================
cat > server_ui.py << 'EOF'
import gradio as gr
import requests
import json
import pandas as pd
import time
import os
import asyncio
from aiogram import Bot
from apscheduler.schedulers.background import BackgroundScheduler

# ================= 1. 全局配置与防重复机制 =================
# 【核心修改】移除了默认值，初始化为空字符串
TG_BOT_TOKEN = ""
TG_CHAT_ID = ""

PROXY_URL = "http://127.0.0.1:7897"
DEFAULT_MAX_MONTHLY_RENEW = 15.0
DEFAULT_MIN_RAM = 1
DEFAULT_CHECK_INTERVAL = 60

HISTORY_FILE = "pushed_ids.txt"
sent_ids = set()

if os.path.exists(HISTORY_FILE):
    with open(HISTORY_FILE, "r", encoding="utf-8") as f:
        for line in f:
            sent_ids.add(line.strip())
    print(f"📂 已从本地加载 {len(sent_ids)} 条历史推送记录。")
else:
    print("📂 未找到历史记录文件，将创建新记录。")

def save_sent_id(item_id):
    try:
        with open(HISTORY_FILE, "a", encoding="utf-8") as f:
            f.write(f"{item_id}\n")
    except Exception as e:
        print(f"⚠️ 保存历史记录失败: {e}")

# ================= 2. 核心采集逻辑 =================
def fetch_all_listings():
    base_url = "https://sign-service.lucffee.com/api/exchange/listings"
    all_data = []
    offset = 0
    limit = 20
    while True:
        params = {"limit": limit, "offset": offset}
        try:
            response = requests.get(base_url, params=params, timeout=15)
            data = response.json()
            listings = data.get("listings", [])
            if not listings: break
            all_data.extend(listings)
            next_offset = data.get("next_offset")
            if next_offset is None: break
            offset = next_offset
            time.sleep(0.3)
        except Exception as e:
            print(f"请求异常: {e}")
            break
    return all_data

# ================= 3. 数据处理与筛选逻辑 =================
def safe_float(value, default=0.0):
    try: return float(value) if value is not None else default
    except: return default

def safe_int(value, default=0):
    try: return int(value) if value is not None else default
    except: return default

def process_data(raw_data, max_price, min_ram, max_monthly_renew, region, keyword):
    processed_items = []
    for item in raw_data:
        try:
            price_cents = item.get('ask_price_cents') or 0
            price_yuan = round(safe_float(price_cents) / 100.0, 2)
            snapshot_str = item.get('snapshot_json')
            if not snapshot_str: continue
            snapshot = json.loads(snapshot_str) if isinstance(snapshot_str, str) else snapshot_str
            if not isinstance(snapshot, dict): continue
            
            area_flag = snapshot.get('area_flag', '') or ''
            area_name = snapshot.get('area_name', '未知') or '未知'
            full_region = f"{area_flag} {area_name}".strip()
            
            due_time_unix = safe_int(snapshot.get('due_time_unix'))
            due_date = "未知"
            if due_time_unix > 0:
                try: due_date = time.strftime('%Y-%m-%d %H:%M', time.localtime(due_time_unix))
                except: due_date = "时间戳异常"
            
            cycle = safe_int(snapshot.get('cycle'))
            renew_cents = safe_float(snapshot.get('renew_price_cents'))
            if cycle == 1:
                renew_monthly_yuan = round(renew_cents / 100.0, 2)
                cycle_desc = "月付"
            elif cycle == 12:
                renew_monthly_yuan = round((renew_cents / 100.0) / 12, 2)
                cycle_desc = "年付"
            else:
                renew_monthly_yuan = round(renew_cents / 100.0, 2)
                cycle_desc = f"{cycle}期"
            
            processed_items.append({
                "商品ID": item.get('id', ''),
                "价格(元)": price_yuan,
                "地区": full_region,
                "CPU(核)": safe_int(snapshot.get('cpu')),
                "内存(GB)": round(safe_float(snapshot.get('memory_mb')) / 1024.0, 2),
                "硬盘(GB)": safe_float(snapshot.get('disk_gb')),
                "流量(GB)": safe_float(snapshot.get('flow_gb')),
                "带宽(Mbps)": safe_int(snapshot.get('bandwidth_mbps')),
                "线路描述": f"{snapshot.get('node_name', '')} ({snapshot.get('node_comment', '')})",
                "计费周期": cycle_desc,
                "月续费价格(元)": renew_monthly_yuan,
                "重置流量价格(元)": round(safe_float(snapshot.get('reset_flow_price_cents')) / 100.0, 2),
                "到期时间": due_date
            })
        except: continue
    
    df = pd.DataFrame(processed_items)
    if not df.empty:
        if max_price > 0: df = df[df["价格(元)"] <= max_price]
        if min_ram > 0: df = df[df["内存(GB)"] >= min_ram]
        if max_monthly_renew > 0: df = df[df["月续费价格(元)"] <= max_monthly_renew]
        if region and region != "全部地区": df = df[df["地区"].str.contains(region, case=False, na=False)]
        if keyword:
            mask = df["地区"].str.contains(keyword, case=False, na=False) | df["线路描述"].str.contains(keyword, case=False, na=False)
            df = df[mask]
        df = df.sort_values(by="价格(元)").reset_index(drop=True)
    return df

is_processing = False
def process_and_filter(max_price, min_ram, max_monthly_renew, region, keyword, progress=gr.Progress()):
    global is_processing
    if is_processing: return pd.DataFrame(), "⚠️ 系统正在采集中，请勿重复点击..."
    try:
        is_processing = True
        progress(0, desc="🚀 正在初始化爬虫引擎...")
        raw_data = fetch_all_listings()
        if not raw_data: return pd.DataFrame(), "⚠️ 采集失败或无数据，请检查网络。"
        progress(0.2, desc=f"📦 已获取 {len(raw_data)} 条原始数据，正在清洗...")
        import time; time.sleep(0.5)
        progress(0.5, desc="🔍 正在根据条件筛选神车...")
        df = process_data(raw_data, max_price, min_ram, max_monthly_renew, region, keyword)
        progress(1.0, desc="✅ 处理完成！")
        summary = f"✅ 采集成功！共扫描 {len(raw_data)} 条，符合筛选条件 {len(df)} 条。"
        return df, summary
    except Exception as e:
        return pd.DataFrame(), f"❌ 发生严重错误: {str(e)}"
    finally:
        is_processing = False

# ================= 4. Telegram 推送功能 =================
async def send_telegram(df):
    if df is None or df.empty: return "⚠️ 没有数据可以推送。"
    # 【核心修改】检查是否为空
    if not TG_BOT_TOKEN or not TG_CHAT_ID:
        return "❌ 请先在后台【Telegram 设置】中配置 Token 和 Chat ID！"
    try:
        bot = Bot(token=TG_BOT_TOKEN)
        sorted_df = df.sort_values(by="价格(元)").reset_index(drop=True)
        total_count = len(sorted_df)
        batch_size = 5
        batches = [sorted_df[i:i + batch_size] for i in range(0, total_count, batch_size)]
        total_batches = len(batches)
        
        msg_header = (
            f"🚨 **VPS 神车雷达触发！** 🚨\n"
            f"🎯 共发现 **{total_count}** 台新机器，"
            f"将分 **{total_batches}** 次为您推送：\n\n"
        )
        await bot.send_message(chat_id=TG_CHAT_ID, text=msg_header, parse_mode="Markdown")
        await asyncio.sleep(1)
        
        sent_count = 0
        for index, batch_df in enumerate(batches):
            current_batch = f"📄 **第 {index + 1}/{total_batches} 批 (共{len(batch_df)}台):**\n\n"
            for _, row in batch_df.iterrows():
                item_msg = (
                    f"💰 **{row['价格(元)']}元** (月续费: {row['月续费价格(元)']}元/{row['计费周期']}) | {row['地区']}\n"
                    f"🖥️ {row['CPU(核)']}C {row['内存(GB)']}G {row['硬盘(GB)']}G | 🌐 {row['带宽(Mbps)']}M\n"
                    f"🔗 {row['线路描述'][:40]}...\n"
                    f"──────────────\n"
                )
                current_batch += item_msg
            await bot.send_message(chat_id=TG_CHAT_ID, text=current_batch, parse_mode="Markdown")
            sent_count += 1
            if index < total_batches - 1: await asyncio.sleep(1.5)
        return f"✅ 推送成功！共分 {sent_count} 次发送，覆盖 {total_count} 台机器。"
    except Exception as e:
        error_msg = str(e)
        print(f"❌ 推送失败详情: {error_msg}")
        return f"❌ 推送失败: {error_msg}"
    finally:
        if 'bot' in locals(): await bot.session.close()

# ================= 5. 自动轮询后台任务 =================
def auto_monitor_job():
    print(f"[{time.strftime('%H:%M:%S')}] ⏱️ 自动轮询开始...")
    try:
        # 【核心修改】如果未配置，则跳过自动推送
        if not TG_BOT_TOKEN or not TG_CHAT_ID:
            print("⚠️ 未配置 Telegram 信息，自动监控暂停。")
            return

        raw_data = fetch_all_listings()
        df = process_data(raw_data, max_price=0, min_ram=DEFAULT_MIN_RAM, max_monthly_renew=DEFAULT_MAX_MONTHLY_RENEW, region="全部地区", keyword="")
        if not df.empty:
            new_items = df[~df["商品ID"].isin(sent_ids)]
            if not new_items.empty:
                print(f"🔥 发现 {len(new_items)} 台新机器，正在推送 TG...")
                sent_ids.update(new_items["商品ID"].tolist())
                for mid in new_items["商品ID"].tolist(): save_sent_id(mid)
                asyncio.run(send_telegram(new_items))
            else: print("😴 暂无新机。")
        else: print("😴 暂无符合条件的机器。")
    except Exception as e: print(f"❌ 自动轮询出错: {e}")

scheduler = BackgroundScheduler()
scheduler.add_job(auto_monitor_job, 'interval', seconds=DEFAULT_CHECK_INTERVAL, id="vps_monitor")
scheduler.start()

# ================= 6. 构建 WebUI 界面 =================
with gr.Blocks(title="VPS 神车监控面板") as app:
    gr.Markdown("# 🚀 VPS 神车自动狙击面板")
    gr.Markdown("⏱️ **后台已启动自动轮询，发现新机将自动推送 TG！**")
    with gr.Row():
        with gr.Column(scale=1):
            gr.Markdown("### 🔍 手动筛选条件")
            max_price = gr.Slider(0, 500, value=0, step=5, label="最高价格 (元) [0表示不限]")
            min_ram = gr.Slider(0, 16, value=0, step=1, label="最低内存 (GB) [0表示不限]")
            max_monthly_renew = gr.Slider(0, 500, value=5, step=5, label="最高月续费价格 (元) [0表示不限]")
            region = gr.Dropdown(choices=["全部地区", "中国香港", "日本", "美国", "中国台湾", "新加坡"], value="全部地区", label="🌍 地区筛选")
            keyword = gr.Textbox(label="🔍 线路关键词", placeholder="例如: CN2, 4837")
            run_btn = gr.Button("🚀 手动采集并筛选", variant="primary")
            
            gr.Markdown("---")
            gr.Markdown("### ⚙️ 后台自动监控设置")
            bg_max_renew = gr.Slider(0, 100, value=10, step=1, label="后台最高月续费 (元)")
            bg_min_ram = gr.Slider(0, 16, value=1, step=1, label="后台最低内存 (GB)")
            bg_interval = gr.Slider(30, 600, value=60, step=10, label="后台轮询间隔 (秒)")
            update_bg_btn = gr.Button("🔄 更新后台监控配置", variant="secondary")
            bg_status = gr.Textbox(label="后台状态", interactive=False)

            # 【核心修改】新增 Telegram 设置模块
            gr.Markdown("---")
            gr.Markdown("### 📬 Telegram 设置")
            gr.Markdown("⚠️ **请在此处输入你的 Token 和 Chat ID，配置后自动监控才会生效。**")
            tg_token_input = gr.Textbox(label="Bot Token", placeholder="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11", type="password")
            tg_chat_id_input = gr.Textbox(label="Chat ID", placeholder="8918146597")
            save_tg_btn = gr.Button("💾 保存 Telegram 配置", variant="primary")
            tg_config_status = gr.Textbox(label="配置状态", interactive=False)

        with gr.Column(scale=3):
            summary_text = gr.Textbox(label="执行摘要", interactive=False)
            result_table = gr.Dataframe(label="筛选结果列表", interactive=False)
            with gr.Row():
                export_btn = gr.Button("📥 一键导出 Excel")
                tg_btn = gr.Button("📲 手动推送 TG", variant="stop")
            export_msg = gr.Textbox(label="导出状态", interactive=False)
            tg_msg = gr.Textbox(label="TG 推送状态", interactive=False)

    def export_to_excel(df):
        if df is None or df.empty: return "⚠️ 当前没有数据可以导出。"
        filename = "VPS神车列表.xlsx"
        df.to_excel(filename, index=False, engine='openpyxl')
        return f"🎉 导出成功！文件已保存至: {os.path.abspath(filename)}"

    def update_background_job(max_renew, min_ram, interval):
        try:
            job = scheduler.get_job("vps_monitor")
            if job:
                job.reschedule('interval', seconds=int(interval))
                global DEFAULT_MAX_MONTHLY_RENEW, DEFAULT_MIN_RAM
                DEFAULT_MAX_MONTHLY_RENEW = max_renew
                DEFAULT_MIN_RAM = min_ram
                return f"✅ 后台配置更新成功！\n月续费上限: {max_renew}元 | 内存下限: {min_ram}GB | 轮询间隔: {interval}秒"
            else: return "❌ 后台任务未找到，请重启程序。"
        except Exception as e: return f"❌ 更新失败: {str(e)}"

    # 【核心修改】新增保存配置的函数
    def save_telegram_config(token, chat_id):
        global TG_BOT_TOKEN, TG_CHAT_ID
        if token and chat_id:
            TG_BOT_TOKEN = token.strip()
            TG_CHAT_ID = chat_id.strip()
            return f"✅ 配置已保存！Token: {TG_BOT_TOKEN[:10]}... ID: {TG_CHAT_ID}"
        else:
            return "❌ Token 和 Chat ID 均不能为空！"

    run_btn.click(fn=process_and_filter, inputs=[max_price, min_ram, max_monthly_renew, region, keyword], outputs=[result_table, summary_text])
    export_btn.click(fn=export_to_excel, inputs=[result_table], outputs=[export_msg])
    tg_btn.click(fn=lambda df: asyncio.run(send_telegram(df)), inputs=[result_table], outputs=[tg_msg])
    update_bg_btn.click(fn=update_background_job, inputs=[bg_max_renew, bg_min_ram, bg_interval], outputs=[bg_status])
    # 【核心修改】绑定保存按钮
    save_tg_btn.click(fn=save_telegram_config, inputs=[tg_token_input, tg_chat_id_input], outputs=[tg_config_status])

if __name__ == "__main__":
    app.launch(theme=gr.themes.Soft(), share=False, server_name="0.0.0.0", server_port=7860)
EOF

# ================= 6. 启动应用 =================
echo "🚀 正在启动 VPS 监控面板..."
echo "访问地址: http://你的VPS_IP:7860"

nohup python3 server_ui.py > app.log 2>&1 &

echo "✅ 部署完成！"
echo "日志查看命令: tail -f app.log"
