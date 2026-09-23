# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## [0.1.3](https://github.com/CadeXLegend/grimuah/compare/v0.1.2...v0.1.3) (2026-09-23)


### Features

* **config:** turn a single rule off by name ([02456b8](https://github.com/CadeXLegend/grimuah/commit/02456b880ac5a4ec50c2bc79ce3dba178236a318))
* **engine:** read a module block's declarations and an assertion's type ([828b0a3](https://github.com/CadeXLegend/grimuah/commit/828b0a3e08a450d7825bc48598eab19501e9d393))
* **engine:** read a type's members from the token stream ([d67be94](https://github.com/CadeXLegend/grimuah/commit/d67be94b7e998429c02504b503e09f3b41ed41f8))
* **engine:** remove biome, freeze the oracle, and add max-nesting-depth ([c52f9a8](https://github.com/CadeXLegend/grimuah/commit/c52f9a8b00e038c5020f0b4d16a79261c8397fc9))
* **ir:** add the node-count sidecar, and the sum that reads it ([642038e](https://github.com/CadeXLegend/grimuah/commit/642038edeb0ecde7de9da771319c7ce97e7b1a5f))
* **rules:** add config-declares-data-only ([7751747](https://github.com/CadeXLegend/grimuah/commit/7751747d6b6ae4a5ba88bd1c8850c3bcf4d227ef))
* **rules:** add max-cyclomatic-complexity ([b20c0cb](https://github.com/CadeXLegend/grimuah/commit/b20c0cbab9afd1f32c7179b32cf974b76c27b594))
* **rules:** add max-file-lines ([9add7f7](https://github.com/CadeXLegend/grimuah/commit/9add7f7bb5ffc50e7a8fc9621d244556d89e66d2))
* **rules:** add max-function-lines ([55f6e76](https://github.com/CadeXLegend/grimuah/commit/55f6e76d04c113c01b3a10352d4b3dcdd14aa480))
* **rules:** add max-parameters ([5ebeb14](https://github.com/CadeXLegend/grimuah/commit/5ebeb143c86567682afc73cf6fd57cbcb0f38718))
* **rules:** add no-async-scalar-failure-return ([e11232c](https://github.com/CadeXLegend/grimuah/commit/e11232cba42446ccfa0df94d85f8317c868777b0))
* **rules:** add no-await-in-loop ([03acf7c](https://github.com/CadeXLegend/grimuah/commit/03acf7c59794a932c877d391a1d9e577f3d284f8))
* **rules:** add no-boolean-flag-argument ([f582629](https://github.com/CadeXLegend/grimuah/commit/f582629919a674e2864df4fb2d0c1559ff9d2756))
* **rules:** add no-duplicated-computation, and its fingerprint family ([57d13ee](https://github.com/CadeXLegend/grimuah/commit/57d13eea4ce30eb7eff981970848eed0500a41d1))
* **rules:** add no-duplicated-function-body, and the run's fingerprint index ([51c02c1](https://github.com/CadeXLegend/grimuah/commit/51c02c1974fe6d05a0e2d80753e7620fbda925ea))
* **rules:** add no-duplicated-statement-text, the statement half of the fingerprints ([f5026ca](https://github.com/CadeXLegend/grimuah/commit/f5026ca7747da2eed5d2e2adb6e16911530bc11a))
* **rules:** add no-duplicated-user-facing-copy, and share the literal-site readers ([2c5a578](https://github.com/CadeXLegend/grimuah/commit/2c5a5782901dfdcb828ca06181833f74c9652cc3))
* **rules:** add no-export-without-consumer, and the run's mention index ([875a1f9](https://github.com/CadeXLegend/grimuah/commit/875a1f923423296f8cfb95dadcb1631ce5c67e5d))
* **rules:** add no-for-of-push-accumulation ([3ac16d5](https://github.com/CadeXLegend/grimuah/commit/3ac16d5600b0393c18c3019b5257b7d6439da7a5))
* **rules:** add no-if-chain-dispatch ([b9fb5e1](https://github.com/CadeXLegend/grimuah/commit/b9fb5e1730d606b109e965081c56b7367c544c92))
* **rules:** add no-import-cycles, and the project pass's import graph ([202177a](https://github.com/CadeXLegend/grimuah/commit/202177ab97b3a964f045d18be083aff333e70285))
* **rules:** add no-literal-duplicating-config-value, the last literal rule ([ef5ae26](https://github.com/CadeXLegend/grimuah/commit/ef5ae265d210476cb4a03bcc720ae0919c6515de))
* **rules:** add no-nested-ternary ([fc93705](https://github.com/CadeXLegend/grimuah/commit/fc937052a95ac359640134fe01113d2eae32badf))
* **rules:** add no-optional-properties ([4b634bc](https://github.com/CadeXLegend/grimuah/commit/4b634bc4c06ed28e1efabc78d7a83e381689ef86))
* **rules:** add no-redundant-allowed-import, the config-reading graph rule ([4a390e5](https://github.com/CadeXLegend/grimuah/commit/4a390e55ed51d6eed465a0ea0fa215083e6455c8))
* **rules:** add no-renamed-duplicate-body ([156031b](https://github.com/CadeXLegend/grimuah/commit/156031bbb596bb4205613d316cef1ce7ca9503ba))
* **rules:** add no-repeated-inline-copy, and share the JavaScript whitespace set ([ca537c9](https://github.com/CadeXLegend/grimuah/commit/ca537c944e433758b0d595577a514369ff56cc2c))
* **rules:** add require-capitalised-user-facing-copy ([792ff85](https://github.com/CadeXLegend/grimuah/commit/792ff85dce5b75c8576def5ee65a1b4f89a645b4))
* **rules:** add require-enum-in-config-file, the first graph-group rule ([9b0df9f](https://github.com/CadeXLegend/grimuah/commit/9b0df9feab075c9367821010d298a368c98a87b7))
* **rules:** add require-enum-over-literal-union ([c674c6f](https://github.com/CadeXLegend/grimuah/commit/c674c6fe112b589b17cf99bf6b601985852690b5))
* **rules:** add require-limit-on-collection-reads ([2231892](https://github.com/CadeXLegend/grimuah/commit/2231892acbfe98b47106cf629fb18599215f8a30))
* **rules:** add require-readonly-collection-signatures ([a4869f3](https://github.com/CadeXLegend/grimuah/commit/a4869f331af4eee73a274f630adceb9bd8e00d39))
* **rules:** add require-readonly-type-members ([29b6894](https://github.com/CadeXLegend/grimuah/commit/29b6894d5a2edb837b9caa41e187d9f632f70bf1))
* **rules:** add require-shared-type-placement, and the index's reverse imports ([e2a1ab5](https://github.com/CadeXLegend/grimuah/commit/e2a1ab500aeef16ec61ceeddc2121b348601b76c))
* **rules:** add the two call-site rules, on a project-wide return-type index ([5f31a3d](https://github.com/CadeXLegend/grimuah/commit/5f31a3d9da6e2d5e07a9dc0c02705b6b687af2b7))
* **rules:** ban any used as a type ([5476813](https://github.com/CadeXLegend/grimuah/commit/547681322e87f9fc7b818e1049689cb1f1b026ce))
* **rules:** bar the three config-naming rules on the config's own size ([dbc79c2](https://github.com/CadeXLegend/grimuah/commit/dbc79c2a42cecba05ce480b7353b721fe4ee74cd))
* **skills:** ship the agent skills through `grimuah skills` ([876524f](https://github.com/CadeXLegend/grimuah/commit/876524f6f8894e2b5af34835c781d6edb72a054a))
* **ts:** add the TypeScript type-node counter ([dd4b830](https://github.com/CadeXLegend/grimuah/commit/dd4b830aaf4a171ab1f9d92a72d8412681169485))
* **ts:** decode a string literal's cooked value, and share the front-end's UTF-16 reader ([6e62c90](https://github.com/CadeXLegend/grimuah/commit/6e62c90ab457fd2160b9405317613e2033a5c842))
* **ts:** record the deltas the front-end drops, and the type extents it skips ([2bc45b0](https://github.com/CadeXLegend/grimuah/commit/2bc45b0a9d98b6d010a8d10dc918faf3ae427178))
* **ts:** record the statement, declaration and class deltas ([56a357b](https://github.com/CadeXLegend/grimuah/commit/56a357b0a87e4f3ba998bb7fc597f7ee0803414c))


### Bug Fixes

* **config:** stop writing allowedImports the DAG already implies ([361a675](https://github.com/CadeXLegend/grimuah/commit/361a67563ed2899a4c7f04b49b081970744e8fe7))
* drop redundant .config.ts from surface suffixes ([331aec2](https://github.com/CadeXLegend/grimuah/commit/331aec2ecbd67d93c1c4c08012b6207f7ba97ed9))
* **init:** state exactOptionalPropertyTypes in the scaffolded tsconfig ([8b92d35](https://github.com/CadeXLegend/grimuah/commit/8b92d35eb463f977a20dab6b6d10016089f23c5b))
* **parser:** match a type argument that holds a multi-member type literal ([4bc88e4](https://github.com/CadeXLegend/grimuah/commit/4bc88e407c823b44f4b3a083c9be18330a79dc2f))
* **parser:** read a class heritage clause as the type reference it is ([8cca37b](https://github.com/CadeXLegend/grimuah/commit/8cca37b4fa6017bb176dcd21a13877a3d79362d9))
* readme improvements ([1c6fe73](https://github.com/CadeXLegend/grimuah/commit/1c6fe73cd2d9dcc5975c0a934daaef322373dceb))
* spacing ([6a4ef52](https://github.com/CadeXLegend/grimuah/commit/6a4ef5222d968ff0843fbe9b7974bc8cad122c50))
* **ts:** stop crashing on a function type in a body-owning annotation ([eee7350](https://github.com/CadeXLegend/grimuah/commit/eee7350167d1b613dbd85e1cd1f0fd45b4dec1f9))
* **ts:** stop the template container ending at a brace pair inside it ([d71e856](https://github.com/CadeXLegend/grimuah/commit/d71e856961895b6e6e895841eb87f66291bc5b08))

## [0.1.2](https://github.com/CadeXLegend/grimuah/compare/v0.1.1...v0.1.2) (2026-09-01)


### Bug Fixes

* update stale 'arch check' reference in structural.grit comment ([4eac8e0](https://github.com/CadeXLegend/grimuah/commit/4eac8e0543a899f919b9c8bb718d2f07537db073))

## [0.1.1](https://github.com/CadeXLegend/grimuah/compare/v0.1.0...v0.1.1) (2026-09-01)


### Bug Fixes

* rename .arch-rules to .grimuah-rules in repo config ([2e379ad](https://github.com/CadeXLegend/grimuah/commit/2e379ad57b70931af6e4ce8247babe043ccfa671))

## 0.1.0 (2026-09-01)


### Features

* dagOrder DAG with biome 2.5 GritQL and Outcome pattern ([5e899a3](https://github.com/CadeXLegend/grimuah/commit/5e899a3367ec11fd68b7b8da1a45baeb0e5b6f5f))
* extract architecture generator alpha from testbed project ([b095b92](https://github.com/CadeXLegend/grimuah/commit/b095b92ff3ea7582e146619b93af078c253cc455))
* rebrand as grimuah with summon alias and release pipeline ([9f7ea0d](https://github.com/CadeXLegend/grimuah/commit/9f7ea0d7e78a02e29e52010bf40fa4c58e0e7ea2))


### Bug Fixes

* generated projects biome-format-clean ([d2a8351](https://github.com/CadeXLegend/grimuah/commit/d2a835170b66800ede6a09562433e7c3276514c2))
* validation issues, biome 2.5 GritQL, unit and e2e tests ([324d879](https://github.com/CadeXLegend/grimuah/commit/324d879c3582689f6e181e08c9e626dff9e5f07c))
