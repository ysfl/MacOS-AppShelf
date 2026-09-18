# 公开仓库内容红线

本仓库是 public。任何一旦进入 git 历史就洗不掉的东西，都必须在**写盘之前**就被挡住，
而不是提交之后靠 `git push --force` 补救——那救不回已经被抓取的内容。

## 永不入库

- 任何凭据：私钥、token、密码、云厂商 access key、签名身份、provisioning profile。
- `.env*`、`*.secret`、`*.pem`、`*.p12`、`*.keystore`、`id_rsa*`、`secrets/` 目录。
- 安装包与校验和：由 `v*` 标签触发的流水线产出并挂到 Release，不进仓库。
- 工作草稿：分析稿、临时报告、编辑器状态。

## 也不得出现的内容

- **绝对个人路径**（`/Users/…`、`/home/…`）：暴露账号名与目录结构，且对读者无用。写相对路径。
- **提交者邮箱**：出现在文件正文里通常是疏忽。
- **与本机其他工作区相关的名称**：见下。

## 本机共用一个磁盘时

这台机器上可能同时存在不公开的工程目录。它们的名称、路径、代号**不能**出现在本仓库里。

问题是：一份"禁止出现的词"清单如果被提交，本身就完成了泄露。

所以清单放在 `Scripts/gates/blocklist.local.txt`，**已 gitignore**：

- 门禁读取它，逐条大小写不敏感地扫描所有被跟踪的文本文件与暂存增量；
- 命中即 error，不是警告；
- 文件不存在时只输出一条 info——干净的 CI 检出本来就没有它，把它判红会让人直接关掉检查。

克隆本仓库后不需要做任何事就能构建；只有与私有工作区共用机器的维护者才需要自建这份清单。
`Scripts/gates/blocklist.local.example.txt` 是模板。

## 四道拦截

| 层 | 位置 | 覆盖 |
|---|---|---|
| 提交 | `.githooks/pre-commit` | 暂存内容的凭据形状、禁入路径、屏蔽词 |
| 推送 | `.githooks/pre-push` | 全部被跟踪文件重扫一遍 |
| 远端 | `.github/workflows/ci.yml` | 同样的检查，不依赖本地钩子被装上 |
| 打包 | `Scripts/build-release.sh` | 构建产物内部，见下 |

本地钩子能被 `--no-verify` 绕过，所以 CI 那一层是必需的，不是重复。

`publication` 检查把 warning 也按 error 处理：泄露与否不是口味问题，没有"观察期"。

## 发布产物也要扫

DMG 里装的是 `.app`，其中 `Info.plist`、`InfoPlist.strings`、`Resources` 下的 JSON 都是文本，
用户可以直接打开读。仓库干净不代表产物干净。

`Scripts/build-release.sh` 在写第一字节 DMG **之前**执行：

```sh
python3 Scripts/gates/scan_products.py dist/AppShelf.app
```

不通过就拒绝打包。因为发布流水线走的就是这个脚本，本地和 CI 拿到同一道拦截。

模式与屏蔽词来自 `gates.py`，不是第二份定义；单独成文件是因为 `gates.py` 的体量已经钉死在
595 行，不允许再增长。

这个检查同样读 `blocklist.local.txt`，同样把 warning 当 error；找不到任何可读文本时判红
而不是判绿——路径写错不该伪装成"扫过了，很干净"。

往 `Resources/` 放文件时同样受本规范约束。
