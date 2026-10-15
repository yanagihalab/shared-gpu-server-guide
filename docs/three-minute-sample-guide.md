# 3分サンプル音声をGPUサーバーで実行する手順書
作成日: 2026年10月15日

## 対象
MacからLGPU01へSSH接続し、録音の先頭180秒を文字起こし・人名処理・整文・要約します。
実行は全てサーバー側CLIで行います。ブラウザ画面やポート転送は不要です。
各コマンドは ```bash と ``` の間だけをコピーしてください。

## 前提
- GPUサーバー: yanagihara_takaaki@GPU_SERVER（GPU_SERVERを実際のIPアドレスまたはホスト名へ置き換える）
- 作業場所: $HOME/interview-demo-nonchina-work/interview-demo-native
- モデルと仮想環境の導入、非中国系モデル3種の取得が完了していること。
- 自動GPU選択、GPU計測修正版、人名未確定時の地名扱い設定を導入済みであること。
- 元の録音: $HOME/2026-09-09_14-26-43.WAV
- ffmpeg、python3、jq、tmux、nvidia-smi、ssが使用できること。
新しいサーバーの初期構築・モデルの初回ダウンロードは本書の対象外です。
本書作成時にGPUサーバーへ接続して状態を確認したわけではありません。

## 処理の内容
音声認識: faster-whisper large-v3
話者分離: NVIDIA Nemotron-3-Diarization
人名処理・整文・要約: ローカルのSwallow 70B
人名と確認できた候補を匿名ラベルへ置換し、未確定の候補は地名扱いで残します。
この方針では実際の人名が残る可能性があり、該当件数を結果に記録します。
対応表と匿名化前の原文はprivateに保存します。音声の声や実名の発音は変更しません。

## 1. MacからGPUサーバーへ接続する

実行場所: Macのターミナル

```bash
ssh -o ConnectTimeout=10 yanagihara_takaaki@GPU_SERVER
```

パスワードを入力します。以降は、指定がある場合を除いてGPUサーバーで実行します。

## 2. 実行中の処理と前提条件を確認する

REC_DATAなどの処理が実行中なら、その終了を待ってからサンプルを実行します。
以下は状態確認です。既存の処理を停止したり、設定を書き換えたりしません。

```bash
(
  set -e
  set -o pipefail
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native"

  for DEMO_CMD in ffmpeg python3 jq tmux nvidia-smi ss; do
    command -v "$DEMO_CMD" >/dev/null
  done

  if [[ -n "$(ss -H -ltn '( sport = :7860 or sport = :8000 )')" ]]; then
    printf '%s\n' 'アプリまたはLLMが起動中です。既存処理の終了を待ってください。'
    exit 2
  fi

  env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 CUDA_VISIBLE_DEVICES=-1 /usr/bin/python3 - <<'CHECK'
from contextlib import ExitStack
import fcntl
import os
from pathlib import Path
import stat
import cli
import gpu_utilization

root = Path.cwd()
paths = [root / 'data/gpu-control' / name for name in
         ('media-batch.lock', 'cli-run.lock', 'runtime-mode.lock')]
runner = root / 'data/rec-data-20261015/runner.lock'
if runner.exists() or runner.is_symlink():
    paths.append(runner)
with ExitStack() as stack:
    for path in paths:
        info = path.lstat()
        if not (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1
                and path.resolve() == path):
            raise SystemExit('実行ロックの所有者・権限・種類を確認してください。')
        stream = stack.enter_context(os.fdopen(
            os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb'))
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('既存の処理が実行中です。終了後に確認し直してください。')
    if not cli._unconfirmed_name_policy():
        raise SystemExit('未確定候補を地名として扱う修正版・設定が未反映です。付録Aを確認してください。')
    policy = gpu_utilization.get_policy()
    if (policy['enabled'] is not True or policy['target_percent'] != 80
            or policy['window_seconds'] != 80):
        raise SystemExit('GPU制御の設定が80%・80秒と異なります。設定を確認してください。')
print('OK: 実行ロック、未確定候補の地名扱い、GPU目標80%・80秒')
CHECK

  jq -e '.profile == "nonchina" and .complete == true and (.models | length == 3)' \
    models/model-revisions-nonchina.json
  bash run_parallel.sh cli-auto --help >/dev/null
  nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.free --format=csv
)
DEMO_SAMPLE_CHECK_EXIT=$?
printf '事前確認の終了コード: %s\n' "$DEMO_SAMPLE_CHECK_EXIT"
```

終了コード0の場合に次へ進みます。設定が未反映なら付録Aを使用します。
確認後に別の処理が始まった場合も、実行時のロック・GPU確認で重複を拒否します。
GPU使用率0%だけでは空きと判定しません。実際の選択は第5節の起動時に行います。

## 3. サーバー上の原本から先頭180秒を作成する

原本は変更しません。サンプルを新しい専用ディレクトリへ保存します。
以前作成した約180.032秒のサンプルと異なり、本書では先頭180秒を切り出します。
原本が見つからない場合は付録Bの転送を済ませてから実行してください。

```bash
(
  set -e
  set -o pipefail
  umask 077
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native"

  printf '%s\n' \
    '85e2555cc06743aa639f122d140001d6573472504be44ad1da91c888e7296422  2026-09-09_14-26-43.WAV' \
    | (cd "$HOME" && sha256sum --check -)

  DEMO_SAMPLE_INPUT_DIR="$PWD/data/sample-180s-$(date +%Y%m%d-%H%M%S)-$RANDOM"
  mkdir -m 700 -- "$DEMO_SAMPLE_INPUT_DIR"
  DEMO_SAMPLE_INPUT="$DEMO_SAMPLE_INPUT_DIR/2026-09-09_14-26-43-sample-180s.wav"

  ffmpeg -nostdin -hide_banner -loglevel error -n \
    -i "$HOME/2026-09-09_14-26-43.WAV" \
    -t 180 -map 0:a:0 -vn -map_metadata -1 \
    -c:a pcm_s16le -ar 16000 -ac 2 "$DEMO_SAMPLE_INPUT"

  python3 - "$DEMO_SAMPLE_INPUT" <<'CHECK'
from pathlib import Path
import sys
import wave
path = Path(sys.argv[1])
with wave.open(str(path), 'rb') as audio:
    seconds = audio.getnframes() / audio.getframerate()
    assert (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) == (2, 16000, 2)
    assert abs(seconds - 180) < 0.01
print(f'OK: サンプル {seconds:.3f}秒、{path.stat().st_size}バイト')
CHECK

  printf '%s\n' "$DEMO_SAMPLE_INPUT" > logs/last-three-minute-sample-input.txt
  printf 'サンプル保存先: %s\n' "$DEMO_SAMPLE_INPUT"
)
DEMO_SAMPLE_PREPARE_EXIT=$?
printf 'サンプル準備の終了コード: %s\n' "$DEMO_SAMPLE_PREPARE_EXIT"
```

終了コード0を確認します。SHA256が不一致なら別の録音なので、処理を始めないでください。

## 4. サンプル専用のtmuxセッションを開く

実行場所: 通常のSSH端末。既存のtmux内にいる場合は、先にCtrl-b、続けてdで離れます。
セッション名はサンプル専用ファイルへ記録します。

```bash
(
  set -e
  umask 077
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native"
  if [[ -n "${TMUX:-}" ]]; then
    printf '%s\n' '通常のSSH端末から実行してください。'
    exit 2
  fi
  DEMO_SAMPLE_SESSION="interview-sample-$(date +%Y%m%d-%H%M%S)-$RANDOM"
  printf '%s\n' "$DEMO_SAMPLE_SESSION" > logs/last-three-minute-sample-session.txt
  printf 'サンプル用セッション: %s\n' "$DEMO_SAMPLE_SESSION"
  env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    TERM=xterm-256color SHELL=/bin/bash \
    tmux -L interview-nonchina -f /dev/null new-session \
    -s "$DEMO_SAMPLE_SESSION" -c "$PWD" '/bin/bash --noprofile --norc -i'
)
```

## 5. 3分サンプルを実行する

実行場所: 第4節で開いたtmux内
以下を1回実行します。出力先は毎回新しく作成し、以前の結果を上書きしません。
本コマンドはREC_DATA全件処理を起動しません。

```bash
(
  set -e
  set -o pipefail
  umask 077
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native"

  DEMO_SAMPLE_INPUT=$(cat logs/last-three-minute-sample-input.txt)
  [[ -f "$DEMO_SAMPLE_INPUT" && ! -L "$DEMO_SAMPLE_INPUT" ]]
  mkdir -p data/cli-runs
  DEMO_SAMPLE_RUN_NAME="sample-180s-$(date +%Y%m%d-%H%M%S)-$RANDOM"
  DEMO_SAMPLE_OUTPUT="$PWD/data/cli-runs/$DEMO_SAMPLE_RUN_NAME"
  DEMO_SAMPLE_LOG="$PWD/logs/$DEMO_SAMPLE_RUN_NAME.log"
  printf '%s\n' "$DEMO_SAMPLE_OUTPUT" > logs/last-three-minute-sample-output.txt
  printf '%s\n' "$DEMO_SAMPLE_LOG" > logs/last-three-minute-sample-log.txt
  printf '入力: %s\n出力先: %s\n' "$DEMO_SAMPLE_INPUT" "$DEMO_SAMPLE_OUTPUT"

  if bash run_parallel.sh cli-auto "$DEMO_SAMPLE_INPUT" \
    --speakers 0 --anonymize-names --continue-unverified-summary \
    --output "$DEMO_SAMPLE_OUTPUT" \
    2>&1 | tee "$DEMO_SAMPLE_LOG"; then
    DEMO_SAMPLE_EXIT=0
  else
    DEMO_SAMPLE_EXIT=$?
  fi
  exit "$DEMO_SAMPLE_EXIT"
)
DEMO_SAMPLE_RUN_EXIT=$?
printf 'サンプル処理の終了コード: %s\n' "$DEMO_SAMPLE_RUN_EXIT"
```

GPUの選択
- 空き0〜3基: 推論を開始せず終了コード2で終了。空いた後に第5節を再実行します。
- 空き4基: 音声処理後、同じ4基でSwallowを起動します。
- 空き5〜7基: 音声処理1基＋Swallow4基の計5基を使用します。
- 空き8基: 音声処理後、Swallowを8基で起動します。
選択したGPUはこの入力の終了まで固定です。処理後は自分で起動したSwallowを終了します。
別の処理を終了する --stop-existing-llm は、この手順では指定しません。

待機の表示
「GPU待機: 計測中」は計測期間分のデータを集めている状態です。
「GPU待機: 整文・要約」は平均使用率の低下を待っている状態です。
目標80%・80秒は平均値の制御であり、瞬間の使用率上限ではありません。
他の処理の使用率も含むため、3分音声でも3分で終了するとは限りません。
初回のモデル読み込み、GPU待機、要約照合の時間によって所要時間が変わります。

端末を離れる場合はCtrl-bを押して離し、続けてdを押します。処理は継続します。
Ctrl-Cは実行端末では本処理を中断します。離れる操作には使わないでください。

## 6. 別端末で状態を10秒ごとに確認する

Macの別ターミナルから第1節のSSH接続を行い、以下を実行します。
サンプル専用の記録を確認します。inspect_auto_progress.pyは既存バッチを参照するため、
今回の単独サンプルの監視には使用しません。

```bash
(
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native" || exit 1
  while true; do
    printf '\033[H\033[2J'
    date --iso-8601=seconds
    if [[ -f logs/last-three-minute-sample-output.txt ]]; then
      DEMO_SAMPLE_OUTPUT=$(cat logs/last-three-minute-sample-output.txt)
      DEMO_SAMPLE_STAGES="$(dirname "$DEMO_SAMPLE_OUTPUT")/.$(basename "$DEMO_SAMPLE_OUTPUT")-auto-stages"
      for DEMO_SAMPLE_STATUS in \
        "$DEMO_SAMPLE_STAGES/auto-status.json" \
        "$DEMO_SAMPLE_STAGES/private/transcription/cli-status.json" \
        "$DEMO_SAMPLE_OUTPUT/cli-status.json"
      do
        [[ -f "$DEMO_SAMPLE_STATUS" ]] || continue
        printf '\n確認先: %s\n' "$DEMO_SAMPLE_STATUS"
        jq '{status, phase, detail, layout, updated_at, exit_code, chosen_allocation}' \
          "$DEMO_SAMPLE_STATUS"
      done
      if [[ -f logs/last-three-minute-sample-log.txt ]]; then
        DEMO_SAMPLE_LOG=$(cat logs/last-three-minute-sample-log.txt)
        if [[ -f "$DEMO_SAMPLE_LOG" ]]; then
          printf '\n直近のログ:\n'
          tail -n 8 -- "$DEMO_SAMPLE_LOG"
        fi
      fi
    else
      printf '%s\n' 'サンプルの実行記録はまだありません。'
    fi
    printf '\n10秒後に更新します。監視終了: Ctrl-C\n'
    sleep 10
  done
)
```

この別端末でCtrl-Cを押すと監視だけが終了します。
status=runningは実行中の記録、phase=gpu_waitはGPU待機の記録です。
completedは完了、partialは一部保存して停止、failedは失敗、interruptedは中断です。
音声処理がcompletedでも、整文・要約やGPU解放が続いている場合があります。
最終判定はauto-status.jsonと、第5節の最終終了コードを確認してください。
更新時刻だけで推論の進行や停止を断定せず、直近ログの工程・バッチの変化も確認します。

処理画面へ戻る場合は、監視を終了して次を実行します。

```bash
cd "$HOME/interview-demo-nonchina-work/interview-demo-native"
DEMO_SAMPLE_SESSION=$(cat logs/last-three-minute-sample-session.txt)
tmux -L interview-nonchina attach-session -t "=$DEMO_SAMPLE_SESSION"
```

## 7. 終了後の結果を確認する

```bash
(
  set -e
  cd "$HOME/interview-demo-nonchina-work/interview-demo-native"
  DEMO_SAMPLE_OUTPUT=$(cat logs/last-three-minute-sample-output.txt)

  if [[ -f "$DEMO_SAMPLE_OUTPUT/cli-status.json" ]]; then
    jq '{status, phase, detail, exit_code, output}' "$DEMO_SAMPLE_OUTPUT/cli-status.json"
  fi
  if [[ -f "$DEMO_SAMPLE_OUTPUT/result.json" ]]; then
    jq '{
      status, cleaned,
      segment_count: (.segments // [] | length),
      editing_quality,
      anonymization: (.anonymization | {
        status, person_count, unconfirmed_name_policy, review_required,
        candidate_verification
      }),
      summary_review,
      grounding: (.summary_audit.grounding | {status, counts})
    }' "$DEMO_SAMPLE_OUTPUT/result.json"
    ls -lh -- "$DEMO_SAMPLE_OUTPUT"
  else
    printf '%s\n' '最終結果はまだありません。第6節の工程状態とログを確認してください。'
  fi
)
```

終了コードの目安
0: 要求した出力の保存が完了。要確認資料が残る場合もあります。
2: GPU不足、実行ロック、前提確認などによる起動拒否。
3: 原文や途中結果を保存して停止。処理全体は未完了です。
その他の非0: 失敗。130は通常Ctrl-Cによる中断です。
実際の原因はauto-status.json、cli-status.json、ログを合わせて確認します。

主な出力
transcription.txt: 人名処理後の話者付き文字起こし全文と時刻。
transcription.srt: 時刻付き字幕形式の文字起こし。
cleaned.txt: 意味を保持して整えた本文。
summary.txt: 根拠発話ID付きの要約。
result.json: 発話、整文、要約、匿名化・根拠照合などの処理情報。
summary-review-required.txt / .json: 要約へ採用できなかった要点の匿名化済み原文。
output-files.json: 通常ファイルと入力名付きファイルの対応。
2026-09-09_14-26-43-sample-180s__*: 入力名を付けた出力コピー。
private/person-name-map.json / .tsv: 人名と匿名ラベルの対応表。
private/person-name-candidates.json: 候補の文脈判定と方針適用の非公開記録。
private/original-result.json: 人名処理前の原文。
出力されるファイルは、完了した工程によって異なります。

privateの原文・対応表には実名が残ります。音声ファイルにも声が残ります。
これらを含む出力全体を共有する場合は、その内容を確認してください。
人名、地名、数字、専門用語、否定、話者の帰属は原音と照合します。
「完了」は処理・保存の完了を示し、内容の正確さを保証するものではありません。

本文を確認する場合:

```bash
cd "$HOME/interview-demo-nonchina-work/interview-demo-native"
DEMO_SAMPLE_OUTPUT=$(cat logs/last-three-minute-sample-output.txt)
less -- "$DEMO_SAMPLE_OUTPUT/summary.txt"
```

lessはqで終了します。要約が未出力なら、まず第6節・第7節で停止理由を確認します。

## 付録A. 未確定候補を地名として扱う修正版が未反映の場合

既存処理が終了してから実行します。以下は更新だけを行い、REC_DATA処理を開始しません。
この配布物は既に構築された今回のGPUサーバー向けです。

Macで転送:

```bash
scp -pr -o ConnectTimeout=10 \
  "/private/tmp/interview-demo-unconfirmed-place-20261015" \
  yanagihara_takaaki@GPU_SERVER:
```

GPUサーバーで導入:

```bash
bash "$HOME/interview-demo-unconfirmed-place-20261015/install_unconfirmed_place.sh"
DEMO_SAMPLE_UPDATE_EXIT=$?
printf '更新の終了コード: %s\n' "$DEMO_SAMPLE_UPDATE_EXIT"
```

終了コード0を確認して第2節からやり直します。
本サンプルではstart_unconfirmed_place.shを実行しません。それはREC_DATAバッチの再開用です。
転送元が消えている場合や導入で不明な版として拒否された場合は、既存ファイルを上書きせず、
修正版の再配布または状態確認を行ってください。

## 付録B. GPUサーバー上に原本がない場合

MacのDownloadsに原本がある場合だけ、Macで次を実行します。
原本を既に転送済みなら、この転送は不要です。

```bash
(
  set -e
  DEMO_SAMPLE_ORIGINAL="$HOME/Downloads/2026-09-09_14-26-43.WAV"
  [[ -f "$DEMO_SAMPLE_ORIGINAL" && ! -L "$DEMO_SAMPLE_ORIGINAL" ]]
  scp -p -o ConnectTimeout=10 "$DEMO_SAMPLE_ORIGINAL" \
    yanagihara_takaaki@GPU_SERVER:
)
```

転送後はGPUサーバーで第3節を実行します。第3節のSHA256確認で録音の一致を確認します。
この手順書の作成時には音源の再生や文字起こし処理を実行していません。
