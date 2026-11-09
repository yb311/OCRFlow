#!/usr/bin/env bash
# Downloads PaddleOCR ONNX models for OCRFlow.
#
# The app can install everything here by itself from its Model Manager
# (模型管理); this script exists for scripted setups and for refreshing the
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

# Each file is pinned to a commit of its repo and to the SHA-256 Hugging Face
# publishes for it — the same pins as PPModelCatalog.swift — so a later push to
# a repo cannot change what gets installed, and a damaged download is refused.
#
# Both write beside the destination and move into place only once the whole
# file has arrived and matches its hash, so a failed or interrupted download
# never leaves a truncated model or dictionary where the app (or the CI cache)
# would take it.
PART=""
trap '[[ -n "${PART}" ]] && rm -f "${PART}" "${PART}.yml"' EXIT

verify() {   # verify <sha256> <file>
    if ! echo "$1  $2" | shasum -a 256 -c --status; then
        echo "SHA-256 mismatch for $2" >&2
        exit 1
    fi
}

fetch() {   # fetch <hf-repo> <revision> <remote file> <sha256> <destination dir> <destination name>
    echo "  ↓ $6"
    PART="$5/$6.part"
    curl --fail --location --progress-bar -o "${PART}" "${HF}/$1/resolve/$2/$3"
    verify "$4" "${PART}"
    mv -f "${PART}" "$5/$6"
    PART=""
}

extract_dict() {   # extract_dict <hf-repo> <revision> <inference.yml sha256> <destination dir> <destination name>
    echo "  ↓ $5"
    PART="$4/$5.part"
    curl --fail --location --silent -o "${PART}.yml" "${HF}/$1/resolve/$2/inference.yml"
    verify "$3" "${PART}.yml"
    python3 "$(dirname "$0")/ppocr_dict.py" < "${PART}.yml" > "${PART}"
    rm -f "${PART}.yml"
    mv -f "${PART}" "$4/$5"
    PART=""
}

# lang_pins <code> → "<revision> <inference.onnx sha256> <inference.yml sha256>"
lang_pins() {
    case "$1" in
        korean)     echo 5c6f574b8e2230adf4287b33e736d71b9fabd28e 92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08 f757fa1c40e99edcf27e9cce879b93eb2a51fa46f5ef39095689b8c37dd75998 ;;
        cyrillic)   echo 2cef88145434beb8afa9dd82d77d799eb1ad7b29 5371ee1ddaa7983cc62d0818d99e982b6804638c85e4f960d59a574094e172e5 5c76cc91fa98410178a09f498db10050d0ec1634a660053d3005ab7be581f501 ;;
        eslav)      echo 9a32171fc5718746875e1a261818884517975013 b3018ef2b09a0250b6e0c8e871c927098363e5fd4df890cc68e8358eb0aaf1bd 025039bac23eb4a308efcefa4d58eab3af440767815c6ba6938468bf6353ee5a ;;
        arabic)     echo 14aaedcd75825982689ecf5cd64ab33ee083215a 799113ebf267fbe742deb99eb36e8d42c9ddc5291ceacf92add41b4d52a59110 21368419e6c016c31db55d316d59e11c128e1913e6e6fe10287084710043d3a6 ;;
        devanagari) echo 251aec19e36739540d35e2cc943f6aa7503b98e5 cb789212ce96c69d3e74728ae4309d179281d68cb3945d0616b67cafab41c986 9bd172dd26440c8ce94d1cde5d5baea6aefdc7cf3c5c8492e0beedef656d4e54 ;;
        el)         echo 8152b89d2ee0e1d4c92decab75fe75e5e3d836b6 2acf17fcaea2bc81b878e311e6263b8885f48bb03796f75f9f30ed3242bbaa6d 17d85b2fe2d2f24cd4ab07bcbc33e0c126859b956ced36e281dc65e2d0c1f0bf ;;
        ta)         echo 0db89798af0d5218fad9ea7ace0557526e9077f1 c6d2b682d2a0ea4cb1fccdba295976f93fd439964d16cdc666cadef531accbee 88a28f5a1bb30cabe38a0985cb5e6619fa4f0c7c78e57a08274674228c5219a6 ;;
        te)         echo f1197c83430241c58c64b0952b3a80366d04eeba 8238bfc46d4cffe720ed6706e3842802467343497428693ff2bfb4e6b3caa36b acebbe53f1831bf28ddfed75aedf58225d7aa5d09100c1d5a9140a2a53b137ce ;;
        th)         echo 1d4adbbafb1034a2fd6618498575b81ea7b69f69 27618be66018f8598ac0a526a593f9f1cebf794e7eded93428e8fb016e537f5f f6ba7fefc38ca1ff398ddafa75d67d16e0b3757c4e6c833adffee98a981766c9 ;;
    esac
}

case "${1:-}" in
    medium)
        mkdir -p "${DEST}"
        echo "Fetching PP-OCRv6 medium into ${DEST}"
        fetch PP-OCRv6_medium_det_onnx 61323801669c338b7891481ec7bac61ce31b576a inference.onnx \
            eb13b44b25bb36f89528b68720af8a61d9cf381176107f465db1757b65d086e1 "${DEST}" PP-OCRv6_medium_det.onnx
        fetch PP-OCRv6_medium_rec_onnx 50c7eacafc52fa7bcf4194e8cd08e46f8558504b inference.onnx \
            9c09abf0957f7968c7586464b7397b84ad2387a0497a351af40e9acc71b673ba "${DEST}" PP-OCRv6_medium_rec.onnx
        echo "Done. Choose it under Settings → Advanced → PP-OCRv6 → Model Tier."
        ;;
    lang)
        lang="${2:-}"
        if [[ -z "${lang}" ]] || [[ " ${LANGS} " != *" ${lang} "* ]]; then
            echo "Unknown language '${lang}'. Available: ${LANGS}" >&2
            exit 1
        fi
        mkdir -p "${DEST}"
        repo="${lang}_PP-OCRv5_mobile_rec_onnx"
        read -r rev model_sha dict_sha <<< "$(lang_pins "${lang}")"
        echo "Fetching ${lang} recogniser into ${DEST}"
        # Dictionary first: a dictionary on its own is ignored, while a
        # recogniser without its own would be read with the wrong charset.
        extract_dict "${repo}" "${rev}" "${dict_sha}" "${DEST}" "${lang}_PP-OCRv5_mobile_rec_dict.txt"
        fetch "${repo}" "${rev}" inference.onnx "${model_sha}" "${DEST}" "${lang}_PP-OCRv5_mobile_rec.onnx"
        echo "Done. Pick it under Settings → Recognition → Language;"
        echo "detection still runs on PP-OCRv6."
        ;;
    bundled)
        # Regenerates what the app ships with. The dictionaries have to come
        # from the same release as the recognisers — a mismatched pair decodes
        # into gibberish, so they are always refreshed together.
        echo "Refreshing bundled models in ${BUNDLED}"
        fetch PP-OCRv6_tiny_det_onnx 2ba1506c0380b8f0b03dd142459aac66d4421f6c inference.onnx \
            193bab7a04fca699a6c82e6abb5b81bdb28177f0abd4062552b04908dafb19f8 "${BUNDLED}" PP-OCRv6_tiny_det.onnx
        fetch PP-OCRv6_tiny_rec_onnx 2612ab37152ae0a677521bae4e1e3d4fb4cf7c30 inference.onnx \
            9ef676d6ed3c88256a2d92c640c44f25b0c40947e111b14b8be8f594091563e6 "${BUNDLED}" PP-OCRv6_tiny_rec.onnx
        fetch PP-OCRv6_small_det_onnx 28fe5895c24fd108c19eb3e8479f4ab385fbfc62 inference.onnx \
            d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e "${BUNDLED}" PP-OCRv6_small_det.onnx
        fetch PP-OCRv6_small_rec_onnx b8f84f0b80c529de40b4fbb3544b84fa7233a513 inference.onnx \
            5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634 "${BUNDLED}" PP-OCRv6_small_rec.onnx
        fetch PP-LCNet_x0_25_textline_ori_onnx aea1f18d97338aaf84b463f90192f2820524a00a inference.onnx \
            94a6a0a0425f2b5f08b5df72086f2d72abe40f1d22f6d12d2cd83674f11f2ff3 "${BUNDLED}" PP-LCNet_x0_25_textline_ori.onnx
        fetch PP-LCNet_x1_0_doc_ori_onnx 7330ab7039123e46af2dc03154b9969aa412c61d inference.onnx \
            af9a0a4f317ff0709ce752067807f819cb15d883f8ecad89f28df1c6ee2d9c92 "${BUNDLED}" PP-LCNet_x1_0_doc_ori.onnx
        extract_dict PP-OCRv6_tiny_rec_onnx 2612ab37152ae0a677521bae4e1e3d4fb4cf7c30 \
            66170210bad538e83fff3c4a3867e547d6bf20b50d64b20347c4b913f3034ea1 "${BUNDLED}" PP-OCRv6_tiny_rec_dict.txt
        extract_dict PP-OCRv6_small_rec_onnx b8f84f0b80c529de40b4fbb3544b84fa7233a513 \
            ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1 "${BUNDLED}" ppocrv6_dict.txt
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
