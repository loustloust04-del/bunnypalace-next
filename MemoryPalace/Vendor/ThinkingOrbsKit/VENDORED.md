# ThinkingOrbsKit (vendored)

- 来源：https://github.com/Jakubantalik/Libraries `packages/thinking-orbs/ports/ios/ThinkingOrbsKit`
- commit `b47ff34dbb37c6fb801cbfc195ec840c8b1924b2`，spec = thinking-orbs 0.3.1
- License MIT（见同目录 LICENSE）
- 只拷 Sources 下 9 个文件，不含 Snapshot.swift（ImageRenderer 快照测试用）和 Tests
- 为什么 vendor 不走 SPM：monorepo 子目录，Package.swift 不在仓库根，SPM 引不了
- 未改一行；升级 = 重拷同名文件

## LICENSE (MIT)

```
MIT License

Copyright (c) 2026 Jakub Antalik

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
```
