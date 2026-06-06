# 🚀 TCP/UDP Network Deep Optimizer & Dashboard

一个用于配置 Linux TCP、UDP 与 RPS 参数的交互式网络调优面板。
支持一键管道流远程运行，并显示实际应用的内核参数。

## ✨ 核心特性

* **IPv4 优先解析**：调整 glibc 地址选择优先级。
* **BBR + FQ 拥塞控制**：检测当前内核支持后启用 BBR，并开启 ECN（显式拥塞通知）。
* **内核参数调优**：按总内存比例配置网络缓冲区、队列与连接参数。
* **RPS 配置**：为可用网络接口配置 RPS CPU mask 与流表。
* **可回退配置**：备份脚本将修改的配置与运行时状态；回退失败时保留恢复数据供重试。

## 📦 快速部署

在你的 Ubuntu / Debian 服务器上，先下载脚本到本地文件，再以 `root` 权限执行：

```bash
curl -fsSLo tcp.sh https://raw.githubusercontent.com/666shen/tcp-dashboard/main/tcp.sh
sudo bash ./tcp.sh
```
> *提示：脚本首次运行会复制当前本地文件至系统；通过管道或进程替换直接运行的方式不会自动安装。仅当 `t` 未被占用时创建快捷命令。*


## ⚖️ 开源协议

基于 [MIT License](LICENSE) 协议开源。
