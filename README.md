安装  
curl -fsSL https://raw.githubusercontent.com/apimsg/deploy_vps_acck/refs/heads/main/deploy_secure.sh -o deploy_secure.sh && bash deploy_secure.sh  
重启  
cd /root/vps_monitor_secure && pkill -9 -f "server_ui.py" && sleep 2 && source venv/bin/activate && nohup python3 server_ui.py > app.log 2>&1 & echo "正在重启，请稍候..." && sleep 3 && tail -n 5 app.log  
卸载  
pkill -f vps_monitor_secure && sudo ufw delete allow 7860/tcp 2>/dev/null; rm -rf ~/vps_monitor_secure && echo "✅ 卸载完成！VPS 已清理干净。" || echo "⚠️ 程序可能未在运行，但目录已清理。"
