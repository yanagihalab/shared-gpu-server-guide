# 共用GPUサーバーのコマンド集

作成日：2026年10月15日

Macから共用GPUサーバーへ接続し、ファイルの転送、利用状況の確認、処理の実行・監視を行うためのコマンド集です。

接続先は `yanagihara_takaaki@GPU_SERVER` と記載しています。`GPU_SERVER` を実際のサーバーのIPアドレスまたはホスト名へ置き換えてください。`input.wav`、`your_program.py`、`run-name`、PIDの `12345` は、実際の名前や番号に置き換えてください。コマンド先頭の `$` などのプロンプトは記載していません。

**各コードブロックの「実行場所」を確認してから実行してください。** Macの `$HOME` はMacのホーム、GPUサーバーの `$HOME` はサーバーのホームを指します。通常、SCP・rsyncは同名ファイルを上書きするため、保存先を確認してください。

## 1. SSHで接続・切断する

**実行場所：Mac**

```bash
ssh -o ConnectTimeout=10 yanagihara_takaaki@GPU_SERVER
```

接続後にユーザー・接続先・現在地を確認します。

**実行場所：GPUサーバー**

```bash
whoami
hostname
pwd
```

接続を終了します。通常のSSH端末で直接実行した処理は、切断時に終了する場合があります。長い処理には第10節のtmuxを使います。

```bash
exit
```

## 2. MacからGPUサーバーへファイルを送る

転送先をホーム直下の `uploads` に作成し、ファイルを送ります。

**実行場所：Mac**

```bash
ssh -o ConnectTimeout=10 yanagihara_takaaki@GPU_SERVER \
  'umask 077; mkdir -p "$HOME/uploads"'

scp -p -o ConnectTimeout=10 \
  "$HOME/Downloads/input.wav" \
  yanagihara_takaaki@GPU_SERVER:uploads/
```

サーバー側の保存先は `$HOME/uploads/input.wav` です。`-p` は更新日時や権限を保持します。転送しただけでは処理は始まりません。

フォルダーごと送る場合は `-r` を付けます。

```bash
scp -rp -o ConnectTimeout=10 \
  "$HOME/Downloads/input_data" \
  yanagihara_takaaki@GPU_SERVER:uploads/
```

保存先はサーバーの `$HOME/uploads/input_data/` です。転送元のフォルダー内に、人名対応表など不要な非公開ファイルが入っていないかも確認してください。

## 3. GPUサーバーからMacのDownloadsへ取得する

**実行場所：Mac**

ファイルを1つ取得します。

```bash
scp -p -o ConnectTimeout=10 \
  yanagihara_takaaki@GPU_SERVER:uploads/result.txt \
  "$HOME/Downloads/"
```

出力フォルダー全体を取得する例です。`run-name` を実際の出力ディレクトリ名に置き換えます。

```bash
scp -rp -o ConnectTimeout=10 \
  yanagihara_takaaki@GPU_SERVER:interview-demo-nonchina-work/interview-demo-native/data/cli-runs/run-name \
  "$HOME/Downloads/"
```

このフォルダーに `private` があれば、その中の原文・人名対応表も取得します。要約だけでよければ、転送元を `.../run-name/summary.txt` に変更してください。

## 4. 大きなフォルダーをrsyncで転送する

rsyncがMacとサーバーの両方にある場合に使います。途中で切断した場合も、同じコマンドを再実行して転送量を抑えられます。

**実行場所：Mac**

アップロード：

```bash
rsync -avP -e 'ssh -o ConnectTimeout=10' \
  "$HOME/Downloads/input_data/" \
  yanagihara_takaaki@GPU_SERVER:uploads/input_data/
```

ダウンロード：

```bash
rsync -avP -e 'ssh -o ConnectTimeout=10' \
  yanagihara_takaaki@GPU_SERVER:interview-demo-nonchina-work/interview-demo-native/data/cli-runs/run-name/ \
  "$HOME/Downloads/run-name/"
```

転送元の末尾 `/` は「フォルダーの中身」を意味します。上記では `input_data` の中身が転送先の `input_data` へ入ります。`-P` は進捗表示と途中ファイルの保持です。転送先のファイルを削除する `--delete` は付けていません。

実際には転送せず、対象だけを確認する場合は `-n` を追加します。

```bash
rsync -avPn -e 'ssh -o ConnectTimeout=10' \
  "$HOME/Downloads/input_data/" \
  yanagihara_takaaki@GPU_SERVER:uploads/input_data/
```

## 5. 転送したファイルが一致するか確認する

**実行場所：Mac**

```bash
shasum -a 256 "$HOME/Downloads/input.wav"
```

**実行場所：GPUサーバー**

```bash
sha256sum "$HOME/uploads/input.wav"
```

先頭の64桁が一致すれば、ファイル内容は一致しています。

チェックサムファイルも一緒に転送する場合：

**実行場所：Mac**

```bash
(
  set -e
  cd "$HOME/Downloads"
  shasum -a 256 input.wav > input.wav.sha256
  scp -p -o ConnectTimeout=10 input.wav input.wav.sha256 \
    yanagihara_takaaki@GPU_SERVER:uploads/
)
```

**実行場所：GPUサーバー**

```bash
(
  cd "$HOME/uploads" || exit 1
  sha256sum --check input.wav.sha256
)
```

`input.wav: OK` と表示されることを確認します。

## 6. GPU全体の使用状況を確認する

**実行場所：GPUサーバー／確認のみ**

```bash
nvidia-smi
```

GPU番号、使用率、GPUメモリ、プロセスを確認できます。GPU使用率が0%でも、モデルがメモリを保持している場合があります。空き表示はGPUの予約・使用権の取得を意味しません。サーバーの割当ルールがある場合は、そのルールに従ってください。

一覧をCSV形式で表示します。

```bash
nvidia-smi \
  --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,memory.free \
  --format=csv
```

GPU 5だけを確認する例：

```bash
nvidia-smi -i 5
```

## 7. GPU使用状況を10秒ごとに自動更新する

**実行場所：GPUサーバー／確認のみ**

画面を書き換えて表示します。

```bash
watch -n 10 nvidia-smi
```

縦に記録を残しながら表示する場合：

```bash
nvidia-smi \
  --query-gpu=index,utilization.gpu,memory.used,memory.free \
  --format=csv -l 10
```

どちらも **Ctrl-Cで監視だけを終了**します。別端末で実行中の計算処理は継続します。

## 8. GPUを使用しているプロセスとユーザーを確認する

**実行場所：GPUサーバー／確認のみ**

計算プロセスと使用GPUのUUIDを表示します。

```bash
nvidia-smi \
  --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
  --format=csv
```

GPU計算プロセスの所有者をまとめて確認します。

```bash
(
  set -e
  set -o pipefail
  DEMO_GPU_PIDS=$(nvidia-smi \
    --query-compute-apps=pid --format=csv,noheader,nounits \
    | awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ {print $1}' \
    | sort -nu | paste -sd, -)
  if [[ -n "$DEMO_GPU_PIDS" ]]; then
    ps -p "$DEMO_GPU_PIDS" -o user:32,pid,ppid,comm:24,etime
  else
    printf '%s\n' '取得できたGPU計算プロセスはありません。'
  fi
)
```

表示されるのは計算用途のプロセスです。画面表示用のXorgなどは `nvidia-smi` の通常表示で確認します。取得中にプロセスが終了した場合や権限制限がある場合、所有者を確認できないことがあります。

特定のPIDだけを確認する例：

```bash
ps -p 12345 -o user:32,pid,ppid,stat,comm:24,etime,time,pcpu
```

`etime` は起動からの経過時間、`time` はCPU時間の累計です。CPU使用率やプロセスの存在だけでは、GPU推論が進んでいるかは判断できません。

## 9. 誰がGPUを何基使用しているか確認する

同じPIDが複数GPUを使うことがあるため、PIDの数では台数を判断しません。次は計算用途のGPU UUIDをユーザーごとに重複を除いて集計します。LGPU01の通常の物理GPU構成向けです。

**実行場所：GPUサーバー／確認のみ**

```bash
python3 - <<'PY'
import csv
from collections import defaultdict
import pwd
import subprocess

def query(fields, kind):
    result = subprocess.run(
        ['nvidia-smi', f'--query-{kind}={fields}', '--format=csv,noheader,nounits'],
        capture_output=True, text=True, check=True, timeout=20)
    return [[value.strip() for value in row] for row in csv.reader(result.stdout.splitlines())]

devices = {uuid: index for index, uuid in query('index,uuid', 'gpu')}
rows = query('gpu_uuid,pid', 'compute-apps')
usage = defaultdict(set)
pids = defaultdict(set)
for uuid, pid in rows:
    if not pid.isdigit():
        raise SystemExit('GPUプロセスのPIDを確認できません。')
    if uuid not in devices:
        raise SystemExit('GPU UUIDと物理GPU番号の対応が未確認です。通常表示で確認してください。')
    result = subprocess.run(['ps', '-p', pid, '-o', 'uid='],
                            capture_output=True, text=True, timeout=10)
    uid = result.stdout.strip()
    if result.returncode == 0 and uid.isdigit():
        try:
            owner = pwd.getpwuid(int(uid)).pw_name
        except KeyError:
            owner = f'UID={uid}'
    else:
        owner = f'未確認(PID={pid})'
    usage[owner].add(uuid)
    pids[owner].add(int(pid))

print(f'{"USER":32} {"台数":>4}  GPU番号 / PID')
for owner in sorted(usage):
    indices = ','.join(sorted((devices[uuid] for uuid in usage[owner]), key=int))
    identifiers = ','.join(map(str, sorted(pids[owner])))
    print(f'{owner:32} {len(usage[owner]):4}  {indices} / {identifiers}')
if not rows:
    print('取得できたGPU計算プロセスはありません。')
PY
```

同じGPUを複数ユーザーが使っている場合、そのGPUは各ユーザーの台数に含まれます。台数を合計しても、サーバーのGPU総数とは一致しない場合があります。

以前作成した集計スクリプトを導入済みなら、次の短いコマンドでも確認できます。

```bash
bash "$HOME/gpu-users.sh"
```

```bash
watch -n 10 bash "$HOME/gpu-users.sh"
```

補助スクリプトでは計算用途と画面表示用途を分けて表示します。上のPythonコマンドは計算用途だけの集計です。

## 10. tmuxでSSH切断後も処理を継続する

**実行場所：GPUサーバー／セッションを作成**

専用ソケット `gpu-work` に `my-job` セッションを作成します。

```bash
tmux -L gpu-work new-session -s my-job
```

開いたtmux内で処理を実行してください。既に同名セッションがある場合は、新規作成せず一覧から状態を確認します。

| 操作 | キー・コマンド |
|---|---|
| 処理を続けたまま画面から離れる | Ctrl-bを押して離し、続けてd |
| 実行中の処理を中断する | 実行端末でCtrl-C |
| コマンド終了後にtmux内のシェルを閉じる | `exit` |

セッション一覧と再接続：

```bash
tmux -L gpu-work list-sessions
```

```bash
tmux -L gpu-work attach-session -t '=my-job'
```

画面に接続せず、直近の表示を確認します。

```bash
tmux -L gpu-work capture-pane -p -t '=my-job' -S -60
```

### 今回のインタビュー処理のtmuxを確認する場合

既存アプリは `interview-nonchina` ソケットを使うため、`gpu-work` と一覧が別です。

```bash
tmux -L interview-nonchina list-sessions
```

```bash
tmux -L interview-nonchina list-panes -a \
  -F 'session=#{session_name} pid=#{pane_pid} command=#{pane_current_command} dead=#{pane_dead} exit=#{pane_dead_status}'
```

再接続する場合は、一覧に出た実際のセッション名を指定します。

```bash
tmux -L interview-nonchina attach-session -t '=実際のセッション名'
```

`dead=1` や `Pane is dead` はそのペインのコマンドが終了した状態です。正常終了か失敗かは終了コードとログで確認します。セッション名が残っているだけでは実行中とは判断できません。

## 11. ログを保存し、終了コードを確認する

**実行場所：GPUサーバー／自分のプログラムを実行**

`your_program.py input.wav` の部分を実際の処理コマンドに置き換えます。

```bash
(
  set -o pipefail
  umask 077
  DEMO_JOB_LOG="$HOME/job-$(date +%Y%m%d-%H%M%S)-$RANDOM.log"
  if python3 your_program.py input.wav 2>&1 | tee "$DEMO_JOB_LOG"; then
    DEMO_JOB_EXIT=0
  else
    DEMO_JOB_EXIT=$?
  fi
  printf '終了コード: %s\nログ: %s\n' "$DEMO_JOB_EXIT" "$DEMO_JOB_LOG"
  exit "$DEMO_JOB_EXIT"
)
```

`pipefail` は、teeの成功だけで本体の失敗を見落とさないための設定です。通常、終了コード0は成功、非0は失敗・中断などです。コードの具体的な意味は各プログラムの仕様を確認してください。

## 12. ログやJSONの進捗を確認する

**実行場所：GPUサーバー／確認のみ**

末尾50行を確認します。

```bash
tail -n 50 "$HOME/job.log"
```

追記を継続表示します。

```bash
tail -f "$HOME/job.log"
```

Ctrl-Cで表示だけを終了します。

長いファイルを閲覧します。`q` で終了、`/error` で文字列を検索できます。

```bash
less "$HOME/job.log"
```

JSONの状態ファイルを整形して表示します。

```bash
jq '{status, phase, detail, updated_at, exit_code}' cli-status.json
```

10秒ごとにJSONを表示します。先に状態ファイルがあるディレクトリへ移動してください。

```bash
watch -n 10 'date --iso-8601=seconds; jq "{status,phase,detail,updated_at,exit_code}" cli-status.json'
```

更新時刻、工程、ログの完了件数などを合わせて確認します。待機処理でも時刻は更新されることがあり、時刻の更新だけでは計算の進行を示しません。

## 13. CPU・メモリ・ディスク・自分のプロセスを確認する

**実行場所：GPUサーバー／確認のみ**

```bash
uptime
free -h
df -h "$HOME"
```

CPU負荷、ホスト側RAM、ホームがあるファイルシステムの空き容量を確認します。GPUメモリは `nvidia-smi` で確認します。

```bash
ps -u "$(id -u)" -o pid,ppid,stat,etime,time,pcpu,pmem,comm:24
```

自分のプロセスを継続監視します。`q` で終了します。

```bash
top -u "$(id -un)"
```

指定フォルダーの使用量を確認します。ファイル数が多いと集計に時間がかかります。

```bash
du -sh "$HOME/interview-demo-nonchina-work/interview-demo-native/data"
```

ログイン中のユーザーを確認します。これはGPU利用者の一覧とは異なります。

```bash
who
w
```

## 14. 待受ポートを確認する

**実行場所：GPUサーバー／確認のみ**

```bash
ss -ltn
```

8000番と7860番だけを確認する例：

```bash
ss -ltn '( sport = :8000 or sport = :7860 )'
```

プロセス情報も付けます。権限によって他ユーザーの情報は表示されないことがあります。

```bash
ss -ltnp '( sport = :8000 or sport = :7860 )'
```

## 15. サーバー内のWeb画面をMacで開く

サーバー側で127.0.0.1:7860にWebアプリが起動している場合の例です。

**実行場所：Mac**

```bash
ssh -o ExitOnForwardFailure=yes -N \
  -L 127.0.0.1:7861:127.0.0.1:7860 \
  yanagihara_takaaki@GPU_SERVER
```

接続中はこの端末を開いたままにし、Macのブラウザで <http://127.0.0.1:7861/> を開きます。Ctrl-Cでトンネルを終了しても、サーバー側アプリそのものは終了しません。

`Address already in use` の場合はMac側の7861を7862などへ変更し、ブラウザのURLも合わせます。このコマンドはWebアプリを起動するものではありません。

## 16. 実行するプログラムにGPUを指定する

**実行場所：GPUサーバー／計算処理を起動**

利用を許可されたGPUに対してのみ指定します。GPU 2のUUIDを取得し、そのGPUだけをプログラムへ見せる例です。

```bash
(
  set -e
  DEMO_VISIBLE_GPU_UUID=$(nvidia-smi -i 2 --query-gpu=uuid --format=csv,noheader)
  CUDA_VISIBLE_DEVICES="$DEMO_VISIBLE_GPU_UUID" python3 your_program.py
)
```

対応するCUDAプログラム内では、そのGPUが通常 `cuda:0` になります。`CUDA_VISIBLE_DEVICES` は可視範囲を指定するもので、GPUの排他予約や使用率の制限にはなりません。

今回のインタビューアプリの `run_parallel.sh cli-auto` は独自にGPUを選択します。この手動指定を追加せず、アプリの自動選択を使用してください。

## 17. 自分の処理を中断する

**実行場所：その処理を実行した端末**

まず **Ctrl-C** を使います。アプリが途中結果の保存やGPU解放を行う場合は、終了まで待ちます。

元の端末へ戻れない場合は、PID・所有者・起動時間を確認します。

**実行場所：GPUサーバー／確認のみ**

```bash
ps -p 12345 -o user:32,pid,ppid,comm:24,etime
```

**以下は停止操作です。** `12345` を確認した自分のPIDへ置き換えてください。所有者が自分と一致する場合だけSIGTERMを送ります。

```bash
(
  DEMO_STOP_PID=12345
  DEMO_STOP_OWNER=$(ps -p "$DEMO_STOP_PID" -o uid= | tr -d '[:space:]')
  if [[ "$DEMO_STOP_OWNER" != "$(id -u)" ]]; then
    printf '%s\n' '自分のプロセスと確認できないため、停止しません。'
    exit 2
  fi
  kill -TERM "$DEMO_STOP_PID"
)
```

同じユーザーの別ジョブを止めないよう、PIDだけでなく処理内容も確認してください。GPU子プロセスが複数あるアプリは、アプリ本来の停止方法を優先します。`pkill python` などの一括停止は使いません。

## 18. 非公開データの権限を確認する

**実行場所：GPUサーバー／確認のみ**

```bash
ls -ld "$HOME/private-work"
ls -l "$HOME/private-work/result.json"
stat -c '権限=%a 所有者=%U 種別=%F %n' "$HOME/private-work/result.json"
```

自分で作成した非公開フォルダー・ファイルの権限を設定する場合：

**実行場所：GPUサーバー／指定した対象の権限を変更**

```bash
chmod 700 "$HOME/private-work"
chmod 600 "$HOME/private-work/result.json"
```

700は所有者だけがアクセスできるフォルダー、600は所有者だけが読み書きできるファイルです。人名対応表・認証設定・匿名化前の原文は、共有用の出力とは区別して管理してください。既存プロジェクト全体へ再帰的にchmodする手順ではありません。

## 19. ファイルを探す・テキストを検索する

**実行場所：GPUサーバー／確認のみ**

```bash
find "$HOME/uploads" -maxdepth 3 -type f -name '*.wav'
```

ripgrepが導入済みの場合、ファイル一覧と文字列検索には次が使えます。

```bash
rg --files "$HOME/interview-demo-nonchina-work/interview-demo-native/logs"
```

```bash
rg -n 'failed|partial|Error|Traceback' "$HOME/job.log"
```

ripgrepがない場合の文字列検索：

```bash
grep -nE 'failed|partial|Error|Traceback' "$HOME/job.log"
```

`.env` や人名対応表を検索対象に含めると、その内容が端末に表示されます。共有するログには認証情報や原文を含めないでください。

## 20. 結果フォルダーをまとめて転送する

出力が確定してから、自分の結果フォルダーをアーカイブにします。`run-name` は実際の出力名へ置き換えます。

**実行場所：GPUサーバー／アーカイブを新規作成**

```bash
(
  set -e
  umask 077
  DEMO_ARCHIVE="$HOME/results-$(date +%Y%m%d-%H%M%S)-$RANDOM.tar.gz"
  tar -czf "$DEMO_ARCHIVE" \
    -C "$HOME/interview-demo-nonchina-work/interview-demo-native/data/cli-runs" \
    run-name
  printf '転送するファイル: %s\n' "$DEMO_ARCHIVE"
  sha256sum "$DEMO_ARCHIVE"
)
```

表示されたアーカイブ名を指定して取得します。

**実行場所：Mac**

```bash
scp -p -o ConnectTimeout=10 \
  yanagihara_takaaki@GPU_SERVER:results-実際の日時と番号.tar.gz \
  "$HOME/Downloads/"
```

自分で作成したアーカイブの中身を確認し、展開します。

```bash
tar -tzf "$HOME/Downloads/results-実際の日時と番号.tar.gz"
```

```bash
(
  set -e
  DEMO_EXTRACT_DIR=$(mktemp -d "$HOME/Downloads/gpu-results.XXXXXX")
  tar -xzf "$HOME/Downloads/results-実際の日時と番号.tar.gz" -C "$DEMO_EXTRACT_DIR"
  printf '展開先: %s\n' "$DEMO_EXTRACT_DIR"
)
```

フォルダー全体をアーカイブにした場合、`private` の原文・人名対応表も含まれます。取得後の配布範囲を確認してください。

## 21. 今回のインタビューアプリで使う確認コマンド

### REC_DATAなどのバッチ進捗

**実行場所：GPUサーバー／確認のみ**

```bash
(
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native" || exit 1
  env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 inspect_auto_progress.py
)
```

これは既存バッチの記録を参照します。単独の3分サンプルは、専用手順書の監視コマンドを使用してください。

### GPU平均使用率の設定と計測

```bash
(
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native" || exit 1
  env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 gpu_utilization.py status \
    | jq '{layout, enabled, target_percent, window_seconds, stale,
           measurement: (.measurement | {warming_up, error, gpus})}'
)
```

`status` は確認のみです。設定変更の `set` は実行中の処理へ影響するため、この確認コマンド集には含めていません。

### 3分サンプルの実行手順

[3分サンプル音声の実行手順書](three-minute-sample-guide.md)

同手順書に、入力の準備、空きGPUを使用するCLI実行、10秒ごとの専用監視、出力内容の確認をまとめています。
