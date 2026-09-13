# Third-Party Notices

本文件承载当前源码分发形态下**已确认**的第三方声明义务,依据
`docs/microbridge-provenance-review-v1.md`(Microbridge Provenance Closure v1,
2026-09-06)的逐行源码比对结论建立;v1.1 文档修复收紧了范围声明(见该报告附录)。未验证事项不在本文件中伪装为已完成。

## Microbridge(MIT License)

- 项目名称:Microbridge
- 官方仓库:https://github.com/DevVig/microbridge
- 比对固定 commit:`fcd0aba7a4fa360ca8690681bd7b049fa3682f10`(main 分支,commit 日期 2026-07-23)
- 上游版权信息:Copyright (c) 2026 Microbridge contributors
- 许可证:MIT License
- 包含来源相关重合片段的本地文件(片段级;行号与完整证据见 provenance 报告第 5 节):
  - `src/codex.rs`
    - L212-215 ≈ 上游 `crates/mb-adapters/src/codex.rs` L90-93(session_meta 处理分支,4 行逐字相同);
    - L307-313 ≈ 上游 L225-231(`is_subagent_source`,同名、同签名、同语义,arm 顺序不同);
    - L208-209、L234-235、L248、L331 等少量惯用行逐字相同。
  - `src/claude.rs`
    - L102-103、L154-155(`sessionId`/`session_id` 与 `status`/`state` 双字段回退,各 2 行逐字相同)。
- 范围说明:上述片段合计约 16 行逐字一致,外加 1 个 6 行同名辅助函数,集中在两个
  journal 解析器。在 Microbridge Provenance Closure v1 实际审查的文件和模块范围内,
  未发现上述片段之外的其他表达性源码重合。未纳入审查的本地模块(见 provenance 报告
  第 3 节)与未读取的上游辅助模块(hosts.rs、title.rs、cursor.rs、daemon 层等)不在
  本结论范围内;本结论亦不覆盖未来新增代码。

MIT 许可声明(适用于上述片段):

Copyright (c) 2026 Microbridge contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Binary Distribution Notices

The candidate builder copies original license/notice files into `licenses/`;
it fails if a dependency has no license metadata or supplied license files.
`licenses/dependency-inventory.json` records the exact Cargo package versions
and license expressions, plus the two .NET runtime packs. This inventory is
generated from the actual build inputs, not a static claim that an unbuilt ZIP
has been checked. Cargo metadata can include build-only dependencies; their
notices are retained conservatively, not claimed to be linked into the binary.

- Rust crates: original `LICENSE*`, `COPYING*`, `NOTICE*`, and similar files
  from the packages resolved by `Cargo.lock`, including Unicode license text.
- Rust standard library: the installed toolchain's copyright inventories and
  license texts under `licenses/rust-toolchain/`. The toolchain inventory can
  cover more components than this application's binary.
- .NET 10.0.12: original license and third-party notice files from
  `Microsoft.NETCore.App.Runtime.win-x64` and
  `Microsoft.WindowsDesktop.App.Runtime.win-x64`, in separate directories.

The project's MIT OR Apache-2.0 choice does not replace these third-party
terms. Final distribution review must check the generated ZIP contents; this
document alone is not proof of package completeness.
