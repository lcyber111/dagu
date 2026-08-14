# dist/

本目录存放离线交付所需的可执行文件，是交付包的一部分：

- `dagu-linux-amd64`（约 190MB）：dagu 编排引擎（编译自 dagu-main）
- `workerd-linux-amd64`（约 80MB）：workerd 控制面逻辑服务（Cloudflare 开源 JS 运行时）

- 这两个二进制都**不提交到 git**（超过 GitHub 单文件 100MB 限制，见根目录 `.gitignore`）
- 获取方式：
  1. 从对应上游源码构建
  2. 或从已有的交付包 / 部署服务器拷贝
  3. workerd 也可以从 GitHub Releases（`workerd-linux-64.gz`）或 npm 包 `workerd` 获取
- 部署时 `scripts/install.sh` 会优先使用 `dist/` 下的二进制；
  workerd 二进制缺失时安装会报错退出（它是必带组件）。
