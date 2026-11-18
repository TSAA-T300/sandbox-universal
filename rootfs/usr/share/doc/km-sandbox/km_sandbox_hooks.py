"""km-sandbox：讓第三方 Python 套件在沙盒內正常運作的匯入掛鉤（openspec: sandbox-workload-image）。

沙盒內看得到主機全部的 CPU，卻讀不到自己的 CPU 配額（沙盒政策不放行 /sys/fs/cgroup）。大部分套件靠
/etc/km-sandbox/env.sh 的環境變數就能照配額運作，下面兩個套件沒有對應的環境變數，要在它們被匯入後調整：

- onnxruntime：預設照主機核心數開執行緒並忙等；在小配額下，markitdown 做檔案類型偵測（magika）的一次推論要幾十秒。
  把「沒有指定執行緒數」的 session 設成 SANDBOX_THREADS（由 env.sh 匯出，沒有時為 1）。
- joblib（scikit-learn 的 n_jobs 靠它）：算 CPU 數時會讀 /sys/fs/cgroup/cpu.max，讀不到就丟 PermissionError，
  只要用到多行程（n_jobs 不是 1）就失敗（2026-11-14 在真的沙盒內實測）。讀不到時當作沒有配額資訊，CPU 數交給
  env.sh 匯出的 LOKY_MAX_CPU_COUNT 決定。

調整失敗（套件的介面變了）時在 stderr 印一行說明，套件照它原本的行為運作，不影響匯入。

本檔由 Dockerfile 複製到 /sandbox/.venv 的 site-packages，並在同一個目錄放一個 .pth 檔（內容是 import 本模組），
直譯器啟動時就會載入，所以這裡只匯入啟動時已經載入的模組。不用 sitecustomize.py：Ubuntu 的系統 Python 自帶一份
（/usr/lib/python3.12/sitecustomize.py），在搜尋路徑上排在 venv 之前，venv 裡的同名檔不會被載入（2026-11-13 在真的沙盒內實測）。
"""

import os
import sys


def _limit_onnxruntime_threads(module):
    base = module.InferenceSession
    session_options = module.SessionOptions
    try:
        threads = max(1, int(os.environ.get("SANDBOX_THREADS", "1")))
    except ValueError:
        threads = 1

    class InferenceSession(base):
        def __init__(self, path_or_bytes, sess_options=None, *args, **kwargs):
            options = sess_options
            try:
                if options is None:
                    options = session_options()
                # 0 代表呼叫端沒有指定；有指定的不動
                if options.intra_op_num_threads == 0:
                    options.intra_op_num_threads = threads
                if options.inter_op_num_threads == 0:
                    options.inter_op_num_threads = 1
            except Exception:
                # onnxruntime 的介面變了：用呼叫端原本的參數，維持它原本的行為
                options = sess_options
            super().__init__(path_or_bytes, options, *args, **kwargs)

    module.InferenceSession = InferenceSession


def _tolerate_unreadable_cgroup(module):
    read_cgroup = module._cpu_count_cgroup

    def _cpu_count_cgroup(os_cpu_count):
        try:
            return read_cgroup(os_cpu_count)
        except OSError:
            return os_cpu_count

    module._cpu_count_cgroup = _cpu_count_cgroup


# 模組名稱 → 該模組載入完成後要做的調整
_PATCHES = {
    "onnxruntime": _limit_onnxruntime_threads,
    "joblib.externals.loky.backend.context": _tolerate_unreadable_cgroup,
}


class _PatchAfterImport:
    """meta path finder：_PATCHES 列出的模組載入完成後，套用對應的調整。

    模組由排在後面的 finder 照常尋找，這裡只在它的 loader 執行完模組之後多做一步。只是查詢模組在不在
    （importlib.util.find_spec）不會執行模組，也就不會套用調整；等到真的匯入時才套用。
    """

    def find_spec(self, fullname, path=None, target=None):
        patch = _PATCHES.get(fullname)
        if patch is None:
            return None
        for finder in sys.meta_path:
            if finder is self or not hasattr(finder, "find_spec"):
                continue
            spec = finder.find_spec(fullname, path, target)
            if spec is not None:
                break
        else:
            return None
        loader = spec.loader
        if loader is None or not hasattr(loader, "exec_module"):
            return spec
        original_exec = loader.exec_module

        def exec_module(module):
            original_exec(module)
            # 有些 loader 是多個模組共用的（例如從 zip 載入時），只對這個模組調整
            if module.__name__ != fullname:
                return
            try:
                patch(module)
            except Exception as error:
                print(
                    f"km-sandbox: 無法調整 {fullname}（{type(error).__name__}: {error}），它照原本的行為運作",
                    file=sys.stderr,
                )

        try:
            loader.exec_module = exec_module
        except (AttributeError, TypeError):
            # 這個 loader 不能改：模組照常匯入，只是不調整
            pass
        return spec


sys.meta_path.insert(0, _PatchAfterImport())
