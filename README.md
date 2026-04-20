# Conda Jupyter Launcher

用于在课程目录中快速选择 Conda 环境并启动 Jupyter Notebook，支持 Windows 和 macOS。

## 目录结构

```text
start_conda_jupyter/start_conda_jupyter/start_conda_jupyter/
├─ Windows/
│  ├─ start_conda_jupyter_win.bat
│  └─ 解压到课程文件夹，右键管理员运行bat文件即可.txt
└─ Macos/
   ├─ start_conda_jupyter_macos.command
   └─ 使用说明（仅首次需要，后续双击打开）.txt
```

## 功能

- 自动检测本机 Conda 安装
- 列出可用环境并按数字选择
- 若未检测到 `torch_env`，先询问是否创建 `torch_env (Python 3.10)`
- 启动前检测以下库，缺失时先询问是否安装
  - `pandas`
  - `scikit-learn`
  - `jupyter notebook`
  - `matplotlib`
  - `torch`
  - `torchvision`
  - `torchaudio`
- 在所选环境中直接打开当前课程目录的 Jupyter Notebook

## Windows

文件位置：
`start_conda_jupyter/start_conda_jupyter/start_conda_jupyter/Windows/start_conda_jupyter_win.bat`

使用方式：

1. 将 `start_conda_jupyter_win.bat` 放到课程文件夹中。
2. 右键选择“以管理员身份运行”更稳妥，普通双击也可以。
3. 按提示选择环境。
4. 如缺少 `torch_env` 或依赖库，按提示输入 `y` 或 `n`。

## macOS

文件位置：
`start_conda_jupyter/start_conda_jupyter/start_conda_jupyter/Macos/start_conda_jupyter_macos.command`

首次运行：

1. 打开“终端”。
2. 输入 `xattr -d com.apple.quarantine `，最后保留一个空格。
3. 将 `start_conda_jupyter_macos.command` 拖入终端并回车。
4. 输入 `chmod +x `，最后保留一个空格。
5. 再次将 `start_conda_jupyter_macos.command` 拖入终端并回车。
6. 后续可直接双击运行。

详细说明见：
`start_conda_jupyter/start_conda_jupyter/start_conda_jupyter/Macos/使用说明（仅首次需要，后续双击打开）.txt`

## Notes

- Windows 版建议放在课程文件夹后再运行，这样打开的 Jupyter Notebook 会直接进入该目录。
- macOS 若仍提示安全限制，可右键脚本后选择“打开”。
- 若本机未安装 Anaconda 或 Miniconda，脚本会提示先安装本地 Conda 环境。
