#!/bin/bash
set -euo pipefail

if [ -z "${GITHUB_WORKSPACE:-}" ]; then
    cd $(dirname $0)
    GITHUB_WORKSPACE=$PWD
fi

: ${STARFORGE:="git+https://github.com/galaxyproject/starforge#egg=starforge"}
: ${STARFORGE_CMD:="starforge --config-file=starforge.yml"}
: ${STARFORGE_VENV:="${GITHUB_WORKSPACE}/venv"}
: ${WHEEL_BUILDER_TYPE:="c-extension"}
: ${DELOCATE:="git+https://github.com/natefoo/delocate@top-level-fix-squash#egg=delocate"}
: ${PY:="3.6"}
: ${OS_NAME:=$(uname -s)}
: ${S3PYPI:="s3pypi"}
: ${S3PYPI_ROOT_INDEX:="git+https://github.com/natefoo/s3pypi-root-index#egg=s3pypi-root-index"}


function setup_build() {
    [ ! -d "$STARFORGE_VENV" ] && python3 -m venv "$STARFORGE_VENV"
    . "${STARFORGE_VENV}/bin/activate"
    pip install "$STARFORGE"
}


function run_build() {
    . "${STARFORGE_VENV}/bin/activate"

    BUILD_WHEEL_METAS=()
    for meta in $(cat "${GITHUB_WORKSPACE}/wheel_metas.txt"); do
        _f=${meta#wheels/} ; wheel=${_f%%/*}
        wheel_type=$($STARFORGE_CMD wheel_type --wheels-config="$meta" "$wheel") || exit $?
        if [ "$wheel_type" == "$WHEEL_BUILDER_TYPE" ]; then
            BUILD_WHEEL_METAS+=("$meta")
        else
            echo "Builder for '$WHEEL_BUILDER_TYPE' skipping wheel '$wheel' of type '$wheel_type'"
        fi
    done

    if [ ${#BUILD_WHEEL_METAS[@]} -eq 0 ]; then
        echo "No wheel changes for builder '$WHEEL_BUILDER_TYPE', terminating"
        exit 0
    fi

    if [ "$WHEEL_BUILDER_TYPE" == 'c-extension' ]; then
        case "$OS_NAME" in
            Darwin)
                STARFORGE_IMAGE_ARGS="--image=ci/osx-${PY}"
                ;;
            Linux)
                STARFORGE_IMAGE_ARGS="--image=ci/linux-${PY}:x86_64 --image=ci/linux-${PY}:i686"
                ;;
        esac
        ./.ci/wheel-cext-builder-setup.sh
    else
        STARFORGE_IMAGE_ARGS="--image=ci/linux-${PY}:${WHEEL_BUILDER_TYPE}"
    fi

    for meta in "${BUILD_WHEEL_METAS[@]}"; do
        _f=${meta#wheels/} ; wheel=${_f%%/*}
        echo "Building '$wheel' wheel from config: $meta"
        $STARFORGE_CMD --debug wheel --wheels-config="$meta" --wheel-dir=wheelhouse $STARFORGE_IMAGE_ARGS "$wheel"; STARFORGE_EXIT_CODE=$?
        if [ "$STARFORGE_EXIT_CODE" -eq 0 ]; then
            echo "Testing '$wheel' wheel"
            $STARFORGE_CMD --debug test_wheel --wheels-config="$meta" --wheel-dir=wheelhouse $STARFORGE_IMAGE_ARGS "$wheel" || exit $?
        elif [ "$STARFORGE_EXIT_CODE" -eq 1 ]; then
            echo "Building '$wheel' wheel failed"
            exit 1
        else
            # why do we not just use -ne 0? what is the significance of this?
            echo "\`starforge wheel\` exited with code '$STARFORGE_EXIT_CODE', skipping wheel test"
        fi
    done
}


function deploy_build() {
    if [ ! -d "${GITHUB_WORKSPACE}/wheelhouse" ]; then
        echo "No wheelhouse dir, so no wheels to deploy"
        exit 0
    fi
    . "${STARFORGE_VENV}/bin/activate"
    pip install "$S3PYPI" "$S3PYPI_ROOT_INDEX"
    #s3pypi --bucket galaxy-wheels --dist-path "${GITHUB_WORKSPACE}/wheelhouse" --region us-east-2 --force
    #s3pypi-root-index --bucket galaxy-wheels --region us-east-2
}


if [ ! -f "${GITHUB_WORKSPACE}/wheel_metas.txt" ]; then
    echo "No wheel_metas.txt, exiting"
    exit 1
else
    echo "wheel_metas.txt contents:"
    cat "${GITHUB_WORKSPACE}/wheel_metas.txt"
fi


case "${1:-}" in
    setup)
        setup_build
        ;;
    build)
        run_build
        ;;
    deploy)
        deploy_build
        ;;
    '')
        setup_build
        run_build
        ;;
    *)
        echo "usage: build.sh [setup|build|deploy]" >&2
        exit 1
        ;;
esac
