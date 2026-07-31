# assets

* **`seal_sandbox.png`** — the logo used in the project README. A 1200px-wide
  build (2x the 600px display width, so it stays crisp on HiDPI) of a
  2816x1536 master. The master is kept out of git as
  `seal_sandbox-master.png`; regenerate this file with:

      magick seal_sandbox-master.png -resize 1200x -strip seal_sandbox.png

* **`code-sandbox-podman-logo.svg`** — an unreferenced 2.7 KB scalable
  alternative: a seal balancing a container box in a broken sandbox frame.
  Kept for favicons, docs, or a dark-theme variant. Uses mid-tone fills only,
  so it reads on both light and dark backgrounds.

Upstream's `claude_docker_sandbox_logo.png` was removed in this fork; all
artwork here is original to it.
