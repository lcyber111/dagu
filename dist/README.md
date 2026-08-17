# dist/

本目录存放离线交付所需的可执行文件，是交付包的一部分：

- `dagu-linux-amd64`（约 190MB）：dagu 编排引擎（编译自 dagu-main）
- `workerd-linux-amd64`（约 80MB）：workerd 控制面逻辑服务（Cloudflare 开源 JS 运行时）
- `python-linux-x86_64.tar.gz`（约 33MB）：便携 Python 3.12.14
  （astral-sh/python-build-standalone `install_only_stripped` 变体，20260814 发布）。
  供没有 python3 的离线 Ubuntu 主机使用：install.sh 检测到系统无 python3 时，
  自动解压到运行目录并在渲染配置时调用；4 个工作流脚本（create/delete/start/reap）
  同样优先用系统 python3、缺失时回退到包内运行时。来源与校验：
  - https://github.com/astral-sh/python-build-standalone/releases/tag/20260814
  - SHA256: 5acfa3e9ba26b51ae161c83aff278da915b590d22373a424b2ba55b8afe91fcc

- 这三个文件都**不提交到 git**（dagu/workerd 超过 GitHub 单文件 100MB 限制；
  见根目录 `.gitignore`，`dist/` 只提交本 README 占位）
- 获取方式：
  1. 从对应上游源码构建
  2. 或从已有的交付包 / 部署服务器拷贝
  3. workerd 也可以从 GitHub Releases（`workerd-linux-64.gz`）或 npm 包 `workerd` 获取
- 部署时 `scripts/install.sh` 会优先使用 `dist/` 下的二进制；
  workerd 二进制缺失时安装会报错退出（它是必带组件）。
