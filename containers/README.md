# containers/

Custom container images for Lane-B backends that need one.

Most backends use an **off-the-shelf** image and need no Dockerfile here:

- **sonarqube** → `docker.io/library/sonarqube:community` (server) +
  `docker.io/sonarsource/sonar-scanner-cli` (scanner), driven by
  [`../backends/sonarqube/backend.sh`](../backends/sonarqube/backend.sh). No
  custom image required.

Add a `Dockerfile.<tool>` here only when a backend needs a bespoke image
(bundled analyzers, plugins, a custom toolchain). Mirror the
[`ffreis-latex-compiler/containers/`](../../../ffreis-latex-compiler) convention:
a `containers/Dockerfile.<tool>` built by a `make <tool>-build` target.

The per-backend lifecycle (`up` / `run` / `collect` / `down`) lives in
`../backends/<tool>/backend.sh`, not here.
