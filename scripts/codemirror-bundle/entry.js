// codemirror.bundle.js 的入口：这里 re-export 的符号就是 markdown-editor.js 可 import 的全部表面。
// 改动后跑 build.sh 重新生成 bundle。
export { basicSetup, minimalSetup } from "codemirror";
export { EditorState, RangeSetBuilder, StateField } from "@codemirror/state";
export { Decoration, EditorView, ViewPlugin, WidgetType, keymap } from "@codemirror/view";
export {
  bracketMatching,
  defaultHighlightStyle,
  foldGutter,
  foldKeymap,
  indentOnInput,
  syntaxHighlighting,
  HighlightStyle
} from "@codemirror/language";
export { markdown, markdownLanguage } from "@codemirror/lang-markdown";
export { SearchQuery, setSearchQuery, replaceNext, replaceAll } from "@codemirror/search";
export { tags } from "@lezer/highlight";

// 旧 bundle 导出的是 @codemirror/search 的内部数组 searchExtensions（searchState + 高亮 + 主题）。
// 这里用公开 API search() 等价提供：它包含同一组扩展，外加默认配置 facet；
// 不含 searchKeymap，所以不会出现 CodeMirror 自带搜索面板，查找 UI 仍由 SwiftUI 侧驱动。
import { search } from "@codemirror/search";
export const searchExtensions = search();
