# Pinned by digest so the toolchain only changes when the digest is bumped
# deliberately (the mutable :stable tag alone could swap out underneath a
# build). Update: docker pull ghcr.io/cirruslabs/flutter:stable && docker
# images --digests, then replace the hash here.
FROM ghcr.io/cirruslabs/flutter:stable@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8

RUN git config --system --add safe.directory /sdks/flutter
RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager "platforms;android-35" "cmake;3.22.1" "ndk;28.2.13676358" \
    && flutter precache --android \
    && chmod -R a+rwX /sdks/flutter /opt/android-sdk-linux

WORKDIR /workspace

ENV PUB_CACHE=/workspace/.dart_tool/pub-cache
ENV GRADLE_USER_HOME=/workspace/.gradle

CMD ["flutter", "--version"]
