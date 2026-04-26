# Changelog

## [0.1.1](https://github.com/Logopher/Vigil/compare/v0.1.0...v0.1.1) (2026-04-26)


### Features

* **aliases:** add ccusage JSONL linkage to session sidecar ([2277132](https://github.com/Logopher/Vigil/commit/2277132f3a352af31c36c6e8bb53f01171bc0b87))
* **aliases:** add repo+branch suffix to session log filenames ([8edbae2](https://github.com/Logopher/Vigil/commit/8edbae2a65f4fa69abad09579d768535277170a8))
* **aliases:** add vigil-set-default command; apply strict policy in vigil ([ad4a45e](https://github.com/Logopher/Vigil/commit/ad4a45e2d0430a74ba84dd5582f2b26b5d3de4c1))
* **aliases:** optional post-scrub env injection for signing-agent ([7e1acd4](https://github.com/Logopher/Vigil/commit/7e1acd4d4226b54c5ba74c22e6f4833a21410127))
* **aliases:** prepend vigil-policy header to session transcripts ([fef31fd](https://github.com/Logopher/Vigil/commit/fef31fd10a4b407f881e4af2548a0e26bb3a7cfc))
* **aliases:** write per-session sidecar metadata JSON ([7326b6f](https://github.com/Logopher/Vigil/commit/7326b6f5039f2ae2a1247088c1a80dd595b61806))
* **aliases:** write session marker file at vigil launch ([86b69e7](https://github.com/Logopher/Vigil/commit/86b69e711ebda4b58704c1d47932a7effe04b7c9))
* **config:** add CI workflow running tests and ShellCheck ([57a000f](https://github.com/Logopher/Vigil/commit/57a000f7f26ba56066f134b6bea93eb3f2abc52e))
* **config:** add scripts/join-sessions.py — pyszz/session/JSONL cost join ([aa17aa6](https://github.com/Logopher/Vigil/commit/aa17aa6a78c91cf825c6149665bf4178e9581dec))
* **config:** enable Dependabot version updates for GitHub Actions ([1b4578f](https://github.com/Logopher/Vigil/commit/1b4578ffdb541794d9825a3a0db820a7f2422ac4))
* **config:** extend sandbox MASTER_DENY_WRITE for installed config paths ([9645caa](https://github.com/Logopher/Vigil/commit/9645caab520ab6d1d6fd4e41203c09529c79427e))
* **config:** install permissive bundle and active-profile tracking ([1a27cf6](https://github.com/Logopher/Vigil/commit/1a27cf69c3e308209d98d0dd052baaadb8e683e2))
* **hooks:** active-policy banner at session start ([2673db1](https://github.com/Logopher/Vigil/commit/2673db19d1a5e517c6c91b5cdaf3e1c9b02f51dd))
* **hooks:** memory-write validation gate (PreToolUse) ([42d51f0](https://github.com/Logopher/Vigil/commit/42d51f01fa9f93d6278a1571dceba8e8c2959c30))
* **hooks:** reintroduce per-tool-call logging via marker file ([cb77f57](https://github.com/Logopher/Vigil/commit/cb77f57a1aa2d9a18313ce1ecf7543a1417b9ffc))
* **policies:** mirror profile persistence denies in strict and dev ([d130045](https://github.com/Logopher/Vigil/commit/d130045fa4c1c30d512105a45ef6304bf0d3a46e))
* **profiles:** add permissive profile bundle ([034e703](https://github.com/Logopher/Vigil/commit/034e703f6084044f33af7f53d6da753dae5b86c4))
* **profiles:** allow ssh-agent socket for commit signing ([297c137](https://github.com/Logopher/Vigil/commit/297c13757828a39d17fa60cf1b5ddc979731385d))
* **profiles:** deny in-process writes to Vigil-installed paths ([6b2a36c](https://github.com/Logopher/Vigil/commit/6b2a36c4c88ccd344d1355915a9d7a0d60906051))
* **profiles:** expand excludedCommands to cover git -C and verify variants ([a8877e7](https://github.com/Logopher/Vigil/commit/a8877e70367f1f35072eb7b9e339b02143100e7b))
* **profiles:** ship settings.local.template.json in installed bundle ([728f146](https://github.com/Logopher/Vigil/commit/728f146417eba62e0049bfa3482da008cfa3f3e0))


### Bug Fixes

* **aliases:** quote arguments to util-linux script(1) via printf '%q' ([9f1a81c](https://github.com/Logopher/Vigil/commit/9f1a81c748037072ef591f1e54627b4be0078065))
* **aliases:** regenerate settings.local.json on set-default profile swap ([87480c4](https://github.com/Logopher/Vigil/commit/87480c495b0c36b5a411fd69f443ab2ddcf314fe))
* **aliases:** rewrite A&&B||C chain as if/else in policy-header prepend ([2ac4a60](https://github.com/Logopher/Vigil/commit/2ac4a604c8c7157a40b94c493d66de81c8eab6d1))
* **config:** install bubblewrap before running tests on CI ([5408bf5](https://github.com/Logopher/Vigil/commit/5408bf544731c06c4dd43947f2830ed936e13c26))
* **config:** pin release-please-action to commit SHA ([e08057f](https://github.com/Logopher/Vigil/commit/e08057f6a53d59645937eae31bb867eb34af1c8f))
* **config:** register Vigil-self specialist agents via frontmatter ([a0c6ae7](https://github.com/Logopher/Vigil/commit/a0c6ae7b818e5af5ed5d6a8d839be46373fa340a))
* **config:** resolve ShellCheck findings across production scripts ([1709015](https://github.com/Logopher/Vigil/commit/1709015e3d11631276d728f0340653474f6fa57d))
* **config:** suppress bandit false positives; fix ruff findings ([184a871](https://github.com/Logopher/Vigil/commit/184a87157282a99bcc84fb87a66aded45a9f23cb))
* **hooks:** sync permissive prune-logs.sh retention to 180d ([700d12c](https://github.com/Logopher/Vigil/commit/700d12c8966740cbc59b6fc087d0ea940b7a36e3))
* **install:** uninstall handles scripts/hooks/ subdirectory ([78fbf4f](https://github.com/Logopher/Vigil/commit/78fbf4f618ce070faef467fade077fee2572f738))
* **profiles:** deny vigil-install-review in default profile baseline ([2a8a3c5](https://github.com/Logopher/Vigil/commit/2a8a3c5888fc4870acbcb19b42dac623bc10d199))
* **profiles:** register specialist agents via frontmatter ([e42d564](https://github.com/Logopher/Vigil/commit/e42d5646c5d86aaec175a77ca060180de8d19b53))
* **profiles:** use excludedCommands carve-out for signing ([42c576f](https://github.com/Logopher/Vigil/commit/42c576f21dd44f32089dcd02e68b2e3c80bfed02))
* **tests:** run install and doctor from repo root for consistent CWD deny-list check ([2188632](https://github.com/Logopher/Vigil/commit/21886322b924ca0426e8f57956ec476cbbcce3f4))
* **tests:** union permission arrays in load_profile ([e56a443](https://github.com/Logopher/Vigil/commit/e56a4438bdb2db0c1432cd6877cf561d6a484b66))


### Refactoring

* **aliases:** discard .log after successful ANSI strip ([fb89337](https://github.com/Logopher/Vigil/commit/fb8933780f88bf413808c1b6535fb5dfbe022fd5))
* **install:** recursive walk for scripts/ tree ([39fdb5e](https://github.com/Logopher/Vigil/commit/39fdb5ea3e2078899b0bd8732323578ecaf9aadb))
* **profiles:** split settings.template.json into settings.json + settings.local.template.json ([74c4040](https://github.com/Logopher/Vigil/commit/74c40405748e7fcd73a9cb4ea58a0adcd85ffca8))


### Documentation

* **config:** add ANALYTICS.md — session log observability and pyszz/ccusage integration ([18d57ac](https://github.com/Logopher/Vigil/commit/18d57ac89929ae372c86ba05d4902427b8deb54f))
* **config:** add ccusage and pyszz to developer tooling backlog ([e327937](https://github.com/Logopher/Vigil/commit/e32793756012fdb4e7692560ec3cc8c12525f891))
* **config:** add FRUGAL.md operator cheatsheet ([20b9d31](https://github.com/Logopher/Vigil/commit/20b9d317bcf237a8def0932037383daf02d22b79))
* **config:** add held transcript-extraction utility to backlog ([c135807](https://github.com/Logopher/Vigil/commit/c1358070aab99393b345f7215888b027575da2d7))
* **config:** add issue templates for bug and idea submissions ([5de2123](https://github.com/Logopher/Vigil/commit/5de21238f10fadfda091712901e3695d940a1b42))
* **config:** add issue-tracker integration item to observability backlog ([d568c89](https://github.com/Logopher/Vigil/commit/d568c89b311b07d3cc8a4d022b7d6cb18bcde221))
* **config:** add permissive-profile design doc; consolidate backlog entries ([3814bf6](https://github.com/Logopher/Vigil/commit/3814bf6f91281f053fa61281732762d155277825))
* **config:** add Stage 2 items for stronger isolation and cloud fit ([1b482b9](https://github.com/Logopher/Vigil/commit/1b482b96eb495cdafc61a74823459435b4559612))
* **config:** add VM isolation design exploration ([c955ebf](https://github.com/Logopher/Vigil/commit/c955ebf87729c72b20bccf0c07e5f249bc6ccd4f))
* **config:** cite upstream Claude Code sandbox docs ([ed28a1c](https://github.com/Logopher/Vigil/commit/ed28a1c022175887285efcd5e6eb0c312c43425a))
* **config:** correct signing claim with falsifying evidence ([260e8cb](https://github.com/Logopher/Vigil/commit/260e8cb659dc4e8240f4ed42d0e0d5e99e14b8d0))
* **config:** document auto-memory as a persistence channel ([b768a97](https://github.com/Logopher/Vigil/commit/b768a970d7535490560e686247437f05aaeaf210))
* **config:** document excludedCommands in design notes ([e7d2e5e](https://github.com/Logopher/Vigil/commit/e7d2e5e394f804ee0b5883afbd45acb57c437f66))
* **config:** document excludedCommands in threat model ([97993b4](https://github.com/Logopher/Vigil/commit/97993b4c578906907c6d47defdd8fbfa3aed8ff6))
* **config:** point project CLAUDE.md to global collaboration rules ([1838b85](https://github.com/Logopher/Vigil/commit/1838b85886734fd54e9673671296cdad124e2ce8))
* **config:** prune rejected-ideas list and clarify its rule ([840f4bd](https://github.com/Logopher/Vigil/commit/840f4bd124e6e53103e81e74d3dd90c2193e0244))
* **config:** record signing-carve-out verification ([44d3721](https://github.com/Logopher/Vigil/commit/44d3721dc567caa526d17530bdc9f4100d17d71f))
* **config:** record signing-investigation resolution ([5b4d1f5](https://github.com/Logopher/Vigil/commit/5b4d1f5cac5f514aab4863d8340f4a946ee6c214))
* **config:** reframe observability section; fix pyszz grep pattern ([181f94b](https://github.com/Logopher/Vigil/commit/181f94bfc6423d746895bbfb5bd8f5ade8c8dfec))
* **config:** remove landed persistence-denies item; add dev/yolo promotion note ([4072d00](https://github.com/Logopher/Vigil/commit/4072d006800e42c6f4f10ba94ee1a5795188c2fb))
* **config:** retarget signing-agent BACKLOG entry ([2c3ce76](https://github.com/Logopher/Vigil/commit/2c3ce7660183125836c914a4d9764eb3cb3ea8bb))
* **config:** retire concluded-investigation section ([d8fbd1a](https://github.com/Logopher/Vigil/commit/d8fbd1a4f262c0c9c9cba9c607d99f796342016b))
* **config:** retriage BACKLOG next-session candidates ([d6f83b0](https://github.com/Logopher/Vigil/commit/d6f83b0a18526528aedab8c5878af90689b417e5))
* **config:** split Out of scope into deferred vs. unanticipated ([49a38c3](https://github.com/Logopher/Vigil/commit/49a38c33cd565ddaf3a8f64b15cdf5226f5657cb))
* **config:** triage backlog — 2026-04-25 ([9c6c058](https://github.com/Logopher/Vigil/commit/9c6c058eca215d36a93bd199a74871c4e16e8aa0))
* **config:** update ANALYTICS.md for implemented observability layer ([d943fdc](https://github.com/Logopher/Vigil/commit/d943fdc299252fe8be898b765f8ce5887c6bcc1d))
* **config:** update architecture section for shipped hook infrastructure ([767b7fe](https://github.com/Logopher/Vigil/commit/767b7fe8e7c95d0902a1834db22cbcae5767e9e5))
* **config:** update CLAUDE.md files for settings template split ([433f266](https://github.com/Logopher/Vigil/commit/433f26658e6991ccf7c243faebe17ab4fcb6f89f))
* **config:** update docs for 24h feature batch ([2fedda5](https://github.com/Logopher/Vigil/commit/2fedda5451278adeb59d44430a037bfff9284915))
* **config:** update pyszz pointer to v2 repo ([1e43e43](https://github.com/Logopher/Vigil/commit/1e43e43859df3ebf19238422e668bf997874271b))
* **profiles:** add frugal-claude bullets to default profile ([e4d2b88](https://github.com/Logopher/Vigil/commit/e4d2b880686378042e47bde7443c730c0c8318c9))
* **profiles:** backport drifted collaboration-rule sections to default profile ([b35238e](https://github.com/Logopher/Vigil/commit/b35238edfe6ae1a074f5f551515df38a5ad5675f))
* **profiles:** consolidate plan-mode-first guidance into decision escalation ([65b95d0](https://github.com/Logopher/Vigil/commit/65b95d0c1773715f3f318dc48b1b87526942da76))
* **profiles:** document cross-project memory-write gate ([8f160a6](https://github.com/Logopher/Vigil/commit/8f160a6d1bd6136ea65514214fd71e65f5bf558e))
* **profiles:** surface sandbox artifacts and blocked Bash commands ([6a04c4b](https://github.com/Logopher/Vigil/commit/6a04c4bdc10a2bdc1289787e2f8a1ea801bbaa70))
* **profiles:** warn that git -C breaks the commit/tag carve-out ([f6991d3](https://github.com/Logopher/Vigil/commit/f6991d3a7ca7ebb3e1a7206aa2dae9744422181a))
