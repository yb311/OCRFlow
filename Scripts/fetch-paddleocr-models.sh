#!/usr/bin/env bash
# Downloads PaddleOCR ONNX models for OCRFlow.
#
# The app can install everything here by itself from Settings → PaddleOCR →
# 模型管理; this script exists for scripted setups and for refreshing the
# models that ship inside the bundle.
#
# Usage:
#   Scripts/fetch-paddleocr-models.sh medium           # PP-OCRv6 medium det + rec
#   Scripts/fetch-paddleocr-models.sh lang korean      # a single-language recogniser
#   Scripts/fetch-paddleocr-models.sh bundled          # refresh the in-bundle models
#   Scripts/fetch-paddleocr-models.sh list             # available language models
set -euo pipefail

DEST="${OCRFLOW_MODELS_DIR:-${HOME}/Library/Application Support/OCRFlow/Models}"
BUNDLED="$(dirname "$0")/../OCRFlow/Resources/PaddleOCR"
# Set OCRFLOW_HF_HOST=hf-mirror.com when huggingface.co is unreachable.
HF="https://${OCRFLOW_HF_HOST:-huggingface.co}/PaddlePaddle"

# PP-OCRv6 reads 50 languages from one model — Simplified and Traditional
# Chinese, English, Japanese and 46 Latin-script languages. These scripts have
# no v6 release, so they stay on the PP-OCRv5 recognisers.
LANGS="korean cyrillic eslav arabic devanagari el ta te th"

fetch() {   # fetch <hf-repo> <remote file> <destination dir> <destination name>
    echo "  ↓ $4"
    curl --fail --location --progress-bar -o "$3/$4" "${HF}/$1/resolve/main/$2"
}

extract_dict() {   # extract_dict <hf-repo> <destination dir> <destination name>
    echo "  ↓ $3"
    curl --fail --location --silent "${HF}/$1/resolve/main/inference.yml" \
        | python3 "$(dirname "$0")/ppocr_dict.py" > "$2/$3"
}

case "${1:-}" in
    medium)
        mkdir -p "${DEST}"
        echo "Fetching PP-OCRv6 medium into ${DEST}"
        fetch PP-OCRv6_medium_det_onnx inference.onnx "${DEST}" PP-OCRv6_medium_det.onnx
        fetch PP-OCRv6_medium_rec_onnx inference.onnx "${DEST}" PP-OCRv6_medium_rec.onnx
        echo "Done. Choose 高精度版 medium in OCRFlow's PaddleOCR settings."
        ;;
    lang)
        lang="${2:-}"
        if [[ -z "${lang}" ]] || [[ " ${LANGS} " != *" ${lang} "* ]]; then
            echo "Unknown language '${lang}'. Available: ${LANGS}" >&2
            exit 1
        fi
        mkdir -p "${DEST}"
        repo="${lang}_PP-OCRv5_mobile_rec_onnx"
        echo "Fetching ${lang} recogniser into ${DEST}"
        fetch "${repo}" inference.onnx "${DEST}" "${lang}_PP-OCRv5_mobile_rec.onnx"
        extract_dict "${repo}" "${DEST}" "${lang}_PP-OCRv5_mobile_rec_dict.txt"
        echo "Done. Pick it under 识别语言 in OCRFlow's PaddleOCR settings;"
        echo "detection still runs on PP-OCRv6."
        ;;
    bundled)
        # Regenerates what the app ships with. The dictionaries have to come
        # from the same release as the recognisers — a mismatched pair decodes
        # into gibberish, so they are always refreshed together.
        echo "Refreshing bundled models in ${BUNDLED}"
        for tier in tiny small; do
            fetch "PP-OCRv6_${tier}_det_onnx" inference.onnx "${BUNDLED}" "PP-OCRv6_${tier}_det.onnx"
            fetch "PP-OCRv6_${tier}_rec_onnx" inference.onnx "${BUNDLED}" "PP-OCRv6_${tier}_rec.onnx"
        done
        fetch PP-LCNet_x0_25_textline_ori_onnx inference.onnx "${BUNDLED}" PP-LCNet_x0_25_textline_ori.onnx
        fetch PP-LCNet_x1_0_doc_ori_onnx inference.onnx "${BUNDLED}" PP-LCNet_x1_0_doc_ori.onnx
        extract_dict PP-OCRv6_tiny_rec_onnx  "${BUNDLED}" PP-OCRv6_tiny_rec_dict.txt
        extract_dict PP-OCRv6_small_rec_onnx "${BUNDLED}" ppocrv6_dict.txt
        echo "Done."
        ;;
    list)
        echo "PP-OCRv5 language recognisers: ${LANGS}"
        echo "(PP-OCRv6 already covers Chinese, English, Japanese and 46 Latin-script languages.)"
        ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
