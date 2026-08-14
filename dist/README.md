# dist/

本目录存放编译好的 dagu 可执行文件，是离线交付包的一部分。

- 期望文件名：`dagu-linux-amd64`（约 190MB）
- 该二进制**不提交到 git**（超过 GitHub 单文件 100MB 限制，见根目录 `.gitignore`）
- 获取方式：
  1. 从 `dagu-main`（上游开源项目）源码交叉编译
  2. 或从已有的交付包 / 部署服务器拷贝
- 部署时 `scripts/install.sh` 会优先使用 `dist/dagu-linux-amd64`，
  找不到时回退到包根目录的 `dagu` 或目标主机上已存在的 dagu。
