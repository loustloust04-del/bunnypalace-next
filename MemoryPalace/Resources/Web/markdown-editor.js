const bridge = window.webkit?.messageHandlers?.memoryPalace;
const editorRoot = document.getElementById("editor");

let view = null;
let fallbackTextArea = null;
let revision = 0;
let applyingNativeUpdate = false;
let debounceTimer = null;
let content = "";
let currentFindQuery = "";
let currentFindIndex = 0;
let currentReplaceText = "";
let lastFindKey = null;
let lastCommandToken = null;
let codeMirrorSearch = null;

function post(message) {
  bridge?.postMessage(message);
}

function currentContent() {
  if (view) return view.state.doc.toString();
  return fallbackTextArea?.value ?? content;
}

function scheduleContentChanged() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    if (applyingNativeUpdate) return;
    content = currentContent();
    post({
      type: "contentChanged",
      content,
      revision
    });
  }, 180);
}

function noteEditorChanged() {
  revision += 1;
  scheduleContentChanged();
}

function setEditorContent(nextContent, nativeRevision = null) {
  if (nativeRevision !== null && nativeRevision < revision) return;
  content = nextContent;
  if (view) {
    if (nextContent === view.state.doc.toString()) return;
    applyingNativeUpdate = true;
    view.dispatch({
      changes: {
        from: 0,
        to: view.state.doc.length,
        insert: nextContent
      }
    });
    applyingNativeUpdate = false;
    return;
  }

  if (fallbackTextArea && fallbackTextArea.value !== nextContent) {
    fallbackTextArea.value = nextContent;
  }
}

function requestSave() {
  content = currentContent();
  post({
    type: "requestSave",
    content
  });
}

function selectedRange(state) {
  const range = state.selection.main;
  return {
    from: Math.min(range.from, range.to),
    to: Math.max(range.from, range.to),
    empty: range.empty
  };
}

function toggleSurround(marker) {
  return (editorView) => {
    const state = editorView.state;
    const range = selectedRange(state);
    const beforeFrom = Math.max(0, range.from - marker.length);
    const before = state.doc.sliceString(beforeFrom, range.from);
    const after = state.doc.sliceString(range.to, range.to + marker.length);

    if (!range.empty && before === marker && after === marker) {
      editorView.dispatch({
        changes: [
          { from: beforeFrom, to: range.from },
          { from: range.to, to: range.to + marker.length }
        ],
        selection: {
          anchor: beforeFrom,
          head: range.to - marker.length
        },
        scrollIntoView: true
      });
      return true;
    }

    if (range.empty) {
      editorView.dispatch({
        changes: { from: range.from, insert: marker + marker },
        selection: { anchor: range.from + marker.length },
        scrollIntoView: true
      });
      return true;
    }

    editorView.dispatch({
      changes: [
        { from: range.from, insert: marker },
        { from: range.to, insert: marker }
      ],
      selection: {
        anchor: range.from + marker.length,
        head: range.to + marker.length
      },
      scrollIntoView: true
    });
    return true;
  };
}

function insertMarkdownLink(editorView) {
  const state = editorView.state;
  const range = selectedRange(state);
  const selected = state.doc.sliceString(range.from, range.to) || "链接文字";
  const replacement = `[${selected}](url)`;
  const urlStart = range.from + selected.length + 3;
  editorView.dispatch({
    changes: { from: range.from, to: range.to, insert: replacement },
    selection: {
      anchor: urlStart,
      head: urlStart + 3
    },
    scrollIntoView: true
  });
  return true;
}

function selectedLines(state) {
  const range = selectedRange(state);
  const end = range.empty ? range.to : Math.max(range.from, range.to - 1);
  const lines = [];
  let line = state.doc.lineAt(range.from);
  const lastLine = state.doc.lineAt(end);
  while (line.number <= lastLine.number) {
    lines.push(line);
    if (line.number === lastLine.number) break;
    line = state.doc.line(line.number + 1);
  }
  return lines;
}

function toggleLinePrefix(removePattern, prefixForLine) {
  return (editorView) => {
    const state = editorView.state;
    const lines = selectedLines(state);
    const nonEmptyLines = lines.filter((line) => line.text.trim().length > 0);
    const targetLines = nonEmptyLines.length ? nonEmptyLines : lines;
    const shouldRemove = nonEmptyLines.length > 0 && nonEmptyLines.every((line) => removePattern.test(line.text));
    const changes = [];

    for (const line of targetLines) {
      if (shouldRemove) {
        const match = line.text.match(removePattern);
        if (!match) continue;
        const indentLength = match[1]?.length ?? 0;
        const marker = match[0].slice(indentLength);
        changes.push({
          from: line.from + indentLength,
          to: line.from + indentLength + marker.length
        });
      } else {
        const indentLength = line.text.match(/^\s*/)?.[0].length ?? 0;
        changes.push({
          from: line.from + indentLength,
          insert: prefixForLine(line)
        });
      }
    }

    if (!changes.length) return false;
    editorView.dispatch({ changes, scrollIntoView: true });
    return true;
  };
}

function setHeading(level) {
  return (editorView) => {
    const state = editorView.state;
    const prefix = "#".repeat(level) + " ";
    const lines = selectedLines(state);
    const shouldRemove = lines.every((line) => line.text.startsWith(prefix));
    const changes = [];

    for (const line of lines) {
      const existing = line.text.match(/^(#{1,6})\s+/);
      if (shouldRemove) {
        changes.push({ from: line.from, to: line.from + prefix.length });
      } else if (existing) {
        changes.push({ from: line.from, to: line.from + existing[0].length, insert: prefix });
      } else {
        changes.push({ from: line.from, insert: prefix });
      }
    }

    editorView.dispatch({ changes, scrollIntoView: true });
    return true;
  };
}

// 键盘浮条的「H」：一颗键循环 正文 → H1 → H2 → H3 → 正文（以第一行的级别为准）
function cycleHeading(editorView) {
  const lines = selectedLines(editorView.state);
  const current = lines[0]?.text.match(/^(#{1,6})\s+/)?.[1].length ?? 0;
  const next = current >= 3 ? 0 : current + 1;
  const insert = next ? "#".repeat(next) + " " : "";
  const changes = lines.map((line) => {
    const existing = line.text.match(/^(#{1,6})\s+/);
    return existing
      ? { from: line.from, to: line.from + existing[0].length, insert }
      : { from: line.from, insert };
  });
  editorView.dispatch({ changes, scrollIntoView: true });
  return true;
}

function insertBlockSnippet(editorView, lines, cursorLineIndex, cursorColumn) {
  const range = editorView.state.selection.main;
  const line = editorView.state.doc.lineAt(range.head);
  const needsLeadingNewline = line.text.trim() !== "";
  const insertAt = needsLeadingNewline ? line.to : line.from;
  const prefix = needsLeadingNewline ? "\n" : "";
  const snippet = prefix + lines.join("\n") + "\n";
  let cursor = insertAt + prefix.length;
  for (let i = 0; i < cursorLineIndex; i += 1) cursor += lines[i].length + 1;
  cursor += cursorColumn;
  editorView.dispatch({
    changes: { from: insertAt, insert: snippet },
    selection: { anchor: cursor },
    scrollIntoView: true
  });
  return true;
}

function insertCodeBlock(editorView) {
  const range = editorView.state.selection.main;
  if (!range.empty) {
    const doc = editorView.state.doc;
    const fromLine = doc.lineAt(range.from);
    const toLine = doc.lineAt(range.to);
    editorView.dispatch({
      changes: [
        { from: fromLine.from, insert: "```\n" },
        { from: toLine.to, insert: "\n```" }
      ],
      scrollIntoView: true
    });
    return true;
  }
  return insertBlockSnippet(editorView, ["```", "", "```"], 1, 0);
}

function insertTable(editorView) {
  return insertBlockSnippet(editorView, ["| 列1 | 列2 |", "| --- | --- |", "|     |     |"], 2, 2);
}

function continueMarkdownList(editorView) {
  const state = editorView.state;
  const selection = state.selection.main;
  if (!selection.empty) return false;

  const line = state.doc.lineAt(selection.head);
  const beforeCursor = state.doc.sliceString(line.from, selection.head);
  const taskMatch = beforeCursor.match(/^(\s*)[-*+]\s+\[[ xX]\]\s+(.*)$/);
  const bulletMatch = beforeCursor.match(/^(\s*)([-*+])\s+(.*)$/);
  const orderedMatch = beforeCursor.match(/^(\s*)(\d+)\.\s+(.*)$/);
  const match = taskMatch || bulletMatch || orderedMatch;
  if (!match) return false;

  const indent = match[1];
  const rest = taskMatch ? taskMatch[2] : match[3];
  if (rest.trim().length === 0) {
    editorView.dispatch({
      changes: { from: line.from + indent.length, to: line.to },
      selection: { anchor: line.from + indent.length },
      scrollIntoView: true
    });
    return true;
  }

  let nextPrefix;
  if (taskMatch) {
    nextPrefix = `${indent}- [ ] `;
  } else if (orderedMatch) {
    nextPrefix = `${indent}${Number(match[2]) + 1}. `;
  } else {
    nextPrefix = `${indent}${match[2]} `;
  }

  const insert = "\n" + nextPrefix;
  editorView.dispatch({
    changes: { from: selection.head, to: selection.head, insert },
    selection: { anchor: selection.head + insert.length },
    scrollIntoView: true
  });
  return true;
}

function updateFallbackTextArea(nextValue, selectionStart, selectionEnd = selectionStart) {
  if (!fallbackTextArea) return false;
  fallbackTextArea.value = nextValue;
  fallbackTextArea.focus();
  fallbackTextArea.setSelectionRange(selectionStart, selectionEnd);
  content = nextValue;
  noteEditorChanged();
  return true;
}

function fallbackRange() {
  if (!fallbackTextArea) return null;
  const from = Math.min(fallbackTextArea.selectionStart, fallbackTextArea.selectionEnd);
  const to = Math.max(fallbackTextArea.selectionStart, fallbackTextArea.selectionEnd);
  return { from, to, empty: from === to };
}

function insertFallbackBlockSnippet(lines, cursorLineIndex, cursorColumn) {
  return () => {
    const range = fallbackRange();
    if (!range) return false;
    const value = fallbackTextArea.value;
    const lineStart = value.lastIndexOf("\n", range.from - 1) + 1;
    const lineEnd = (() => {
      const idx = value.indexOf("\n", range.from);
      return idx < 0 ? value.length : idx;
    })();
    const currentLine = value.slice(lineStart, lineEnd);
    const needsLeadingNewline = currentLine.trim() !== "";
    const insertAt = needsLeadingNewline ? lineEnd : lineStart;
    const prefix = needsLeadingNewline ? "\n" : "";
    const snippet = prefix + lines.join("\n") + "\n";
    let cursor = insertAt + prefix.length;
    for (let i = 0; i < cursorLineIndex; i += 1) cursor += lines[i].length + 1;
    cursor += cursorColumn;
    return updateFallbackTextArea(value.slice(0, insertAt) + snippet + value.slice(insertAt), cursor);
  };
}

function toggleFallbackSurround(marker) {
  return () => {
    const range = fallbackRange();
    if (!range) return false;
    const value = fallbackTextArea.value;
    const beforeFrom = Math.max(0, range.from - marker.length);
    const before = value.slice(beforeFrom, range.from);
    const after = value.slice(range.to, range.to + marker.length);

    if (!range.empty && before === marker && after === marker) {
      const nextValue = value.slice(0, beforeFrom) + value.slice(range.from, range.to) + value.slice(range.to + marker.length);
      return updateFallbackTextArea(nextValue, beforeFrom, range.to - marker.length);
    }

    if (range.empty) {
      const nextValue = value.slice(0, range.from) + marker + marker + value.slice(range.to);
      return updateFallbackTextArea(nextValue, range.from + marker.length);
    }

    const selected = value.slice(range.from, range.to);
    const nextValue = value.slice(0, range.from) + marker + selected + marker + value.slice(range.to);
    return updateFallbackTextArea(nextValue, range.from + marker.length, range.to + marker.length);
  };
}

function insertFallbackMarkdownLink() {
  const range = fallbackRange();
  if (!range) return false;
  const value = fallbackTextArea.value;
  const selected = value.slice(range.from, range.to) || "链接文字";
  const replacement = `[${selected}](url)`;
  const urlStart = range.from + selected.length + 3;
  const nextValue = value.slice(0, range.from) + replacement + value.slice(range.to);
  return updateFallbackTextArea(nextValue, urlStart, urlStart + 3);
}

function fallbackSelectedLineSpans(value, from, to) {
  const safeEnd = from === to ? to : Math.max(from, to - 1);
  const spans = [];
  let lineStart = value.lastIndexOf("\n", Math.max(0, from - 1)) + 1;
  while (lineStart <= safeEnd) {
    const newline = value.indexOf("\n", lineStart);
    const lineEnd = newline < 0 ? value.length : newline;
    spans.push({
      from: lineStart,
      to: lineEnd,
      text: value.slice(lineStart, lineEnd)
    });
    if (newline < 0) break;
    lineStart = newline + 1;
  }
  return spans;
}

function applyFallbackLineChanges(spans, changes) {
  if (!changes.length) return false;
  const value = fallbackTextArea.value;
  let nextValue = value;
  let totalDelta = 0;
  for (const change of changes.slice().reverse()) {
    const insert = change.insert ?? "";
    nextValue = nextValue.slice(0, change.from) + insert + nextValue.slice(change.to ?? change.from);
    totalDelta += insert.length - ((change.to ?? change.from) - change.from);
  }
  return updateFallbackTextArea(
    nextValue,
    spans[0].from,
    Math.max(spans[0].from, spans[spans.length - 1].to + totalDelta)
  );
}

function toggleFallbackLinePrefix(removePattern, prefix) {
  return () => {
    const range = fallbackRange();
    if (!range) return false;
    const value = fallbackTextArea.value;
    const spans = fallbackSelectedLineSpans(value, range.from, range.to);
    const nonEmptySpans = spans.filter((line) => line.text.trim().length > 0);
    const targetSpans = nonEmptySpans.length ? nonEmptySpans : spans;
    const shouldRemove = nonEmptySpans.length > 0 && nonEmptySpans.every((line) => removePattern.test(line.text));
    const changes = [];

    for (const line of targetSpans) {
      if (shouldRemove) {
        const match = line.text.match(removePattern);
        if (!match) continue;
        const indentLength = match[1]?.length ?? 0;
        const marker = match[0].slice(indentLength);
        changes.push({
          from: line.from + indentLength,
          to: line.from + indentLength + marker.length
        });
      } else {
        const indentLength = line.text.match(/^\s*/)?.[0].length ?? 0;
        changes.push({
          from: line.from + indentLength,
          insert: prefix
        });
      }
    }

    return applyFallbackLineChanges(spans, changes);
  };
}

function setFallbackHeading(level) {
  return () => {
    const range = fallbackRange();
    if (!range) return false;
    const value = fallbackTextArea.value;
    const prefix = "#".repeat(level) + " ";
    const spans = fallbackSelectedLineSpans(value, range.from, range.to);
    const shouldRemove = spans.every((line) => line.text.startsWith(prefix));
    const changes = [];

    for (const line of spans) {
      const existing = line.text.match(/^(#{1,6})\s+/);
      if (shouldRemove) {
        changes.push({ from: line.from, to: line.from + prefix.length });
      } else if (existing) {
        changes.push({ from: line.from, to: line.from + existing[0].length, insert: prefix });
      } else {
        changes.push({ from: line.from, insert: prefix });
      }
    }

    return applyFallbackLineChanges(spans, changes);
  };
}

function continueFallbackMarkdownList() {
  const range = fallbackRange();
  if (!range || !range.empty) return false;
  const value = fallbackTextArea.value;
  const lineStart = value.lastIndexOf("\n", Math.max(0, range.from - 1)) + 1;
  const beforeCursor = value.slice(lineStart, range.from);
  const taskMatch = beforeCursor.match(/^(\s*)[-*+]\s+\[[ xX]\]\s+(.*)$/);
  const bulletMatch = beforeCursor.match(/^(\s*)([-*+])\s+(.*)$/);
  const orderedMatch = beforeCursor.match(/^(\s*)(\d+)\.\s+(.*)$/);
  const match = taskMatch || bulletMatch || orderedMatch;
  if (!match) return false;

  const indent = match[1];
  const rest = taskMatch ? taskMatch[2] : match[3];
  if (rest.trim().length === 0) {
    const nextValue = value.slice(0, lineStart + indent.length) + value.slice(range.from);
    return updateFallbackTextArea(nextValue, lineStart + indent.length);
  }

  let nextPrefix;
  if (taskMatch) {
    nextPrefix = `${indent}- [ ] `;
  } else if (orderedMatch) {
    nextPrefix = `${indent}${Number(match[2]) + 1}. `;
  } else {
    nextPrefix = `${indent}${match[2]} `;
  }
  const insert = "\n" + nextPrefix;
  const nextValue = value.slice(0, range.from) + insert + value.slice(range.to);
  return updateFallbackTextArea(nextValue, range.from + insert.length);
}

const markdownCommands = {
  bold: toggleSurround("**"),
  italic: toggleSurround("*"),
  code: toggleSurround("`"),
  link: insertMarkdownLink,
  heading1: setHeading(1),
  heading2: setHeading(2),
  heading3: setHeading(3),
  headingCycle: cycleHeading,
  orderedList: toggleLinePrefix(/^(\s*)\d+\.\s+/, () => "1. "),
  bulletList: toggleLinePrefix(/^(\s*)[-*+]\s+/, () => "- "),
  taskList: toggleLinePrefix(/^(\s*)[-*+]\s+\[[ xX]\]\s+/, () => "- [ ] "),
  quote: toggleLinePrefix(/^(\s*)>\s?/, () => "> "),
  codeBlock: insertCodeBlock,
  table: insertTable
};

const fallbackMarkdownCommands = {
  bold: toggleFallbackSurround("**"),
  italic: toggleFallbackSurround("*"),
  code: toggleFallbackSurround("`"),
  link: insertFallbackMarkdownLink,
  heading1: setFallbackHeading(1),
  heading2: setFallbackHeading(2),
  heading3: setFallbackHeading(3),
  orderedList: toggleFallbackLinePrefix(/^(\s*)\d+\.\s+/, "1. "),
  bulletList: toggleFallbackLinePrefix(/^(\s*)[-*+]\s+/, "- "),
  taskList: toggleFallbackLinePrefix(/^(\s*)[-*+]\s+\[[ xX]\]\s+/, "- [ ] "),
  quote: toggleFallbackLinePrefix(/^(\s*)>\s?/, "> "),
  codeBlock: insertFallbackBlockSnippet(["```", "", "```"], 1, 0),
  table: insertFallbackBlockSnippet(["| 列1 | 列2 |", "| --- | --- |", "|     |     |"], 2, 2)
};

function runMarkdownCommand(name) {
  const command = view ? markdownCommands[name] : fallbackMarkdownCommands[name];
  if (!command) return false;
  const handled = view ? command(view) : command();
  if (handled && view) view.focus();
  return handled;
}

function findMatches(query) {
  const body = currentContent();
  if (!query) return [];

  const lowerBody = body.toLocaleLowerCase();
  const lowerQuery = query.toLocaleLowerCase();
  const matches = [];
  let offset = 0;
  while (offset < lowerBody.length) {
    const index = lowerBody.indexOf(lowerQuery, offset);
    if (index < 0) break;
    matches.push({
      from: index,
      to: index + query.length
    });
    offset = Math.max(index + query.length, index + 1);
  }
  return matches;
}

function codeMirrorFindMatches(query) {
  if (!view || !codeMirrorSearch) return null;

  const searchQuery = new codeMirrorSearch.SearchQuery({
    search: query,
    caseSensitive: false,
    literal: true,
    replace: currentReplaceText
  });
  const matches = [];
  if (!query) return { searchQuery, matches };

  const cursor = searchQuery.getCursor(view.state);
  while (!cursor.next().done) {
    matches.push({
      from: cursor.value.from,
      to: cursor.value.to
    });
  }
  return { searchQuery, matches };
}

function applyCodeMirrorFind(query, index = 0) {
  const result = codeMirrorFindMatches(query);
  if (!result) return false;

  currentFindQuery = query || "";
  const { searchQuery, matches } = result;
  currentFindIndex = matches.length ? Math.max(0, Math.min(index, matches.length - 1)) : 0;
  const effects = [codeMirrorSearch.setSearchQuery.of(searchQuery)];
  const activeMatch = matches[currentFindIndex];
  const update = { effects };

  if (activeMatch) {
    update.selection = {
      anchor: activeMatch.from,
      head: activeMatch.to
    };
    update.scrollIntoView = true;
  }

  view.dispatch(update);
  post({
    type: "findResult",
    count: matches.length,
    index: matches.length ? currentFindIndex + 1 : 0
  });
  return true;
}

function applyFind(query, index = 0) {
  if (view && codeMirrorSearch && applyCodeMirrorFind(query, index)) return;

  currentFindQuery = query || "";
  const matches = findMatches(currentFindQuery);
  currentFindIndex = matches.length ? Math.max(0, Math.min(index, matches.length - 1)) : 0;
  const activeMatch = matches[currentFindIndex];

  if (view) {
    if (matches.length) {
      view.dispatch({
        selection: {
          anchor: activeMatch.from,
          head: activeMatch.to
        },
        scrollIntoView: true
      });
    }
  } else {
    if (fallbackTextArea && activeMatch) {
      fallbackTextArea.focus();
      fallbackTextArea.setSelectionRange(activeMatch.from, activeMatch.to);
      const lineHeight = 22;
      const line = currentContent().slice(0, activeMatch.from).split("\n").length - 1;
      fallbackTextArea.scrollTop = Math.max(0, line * lineHeight - fallbackTextArea.clientHeight / 3);
    }
  }

  post({
    type: "findResult",
    count: matches.length,
    index: matches.length ? currentFindIndex + 1 : 0
  });
}

function installFallbackEditor() {
  fallbackTextArea = document.createElement("textarea");
  fallbackTextArea.className = "fallback-editor";
  fallbackTextArea.setAttribute("aria-label", "Markdown 编辑器");
  fallbackTextArea.spellcheck = false;
  fallbackTextArea.value = content;
  fallbackTextArea.addEventListener("input", noteEditorChanged);
  fallbackTextArea.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
      event.preventDefault();
      requestSave();
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "b") {
      event.preventDefault();
      runMarkdownCommand("bold");
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "i") {
      event.preventDefault();
      runMarkdownCommand("italic");
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      runMarkdownCommand("link");
    } else if (event.key === "Enter" && continueFallbackMarkdownList()) {
      event.preventDefault();
    }
  });
  editorRoot.replaceChildren(fallbackTextArea);
}

// 替换走 CodeMirror search 现成命令：查询（含替换文本）已由 applyFind 设好、当前项已选中。
// replaceNext 换完选区停在替换后的文字上；回报「它后面第一处」的序号让 Swift 的「第几个」跟上
//（替换文本含查找词时计数不减，不报会原地反复替换）。全部替换后回到第 1 处
function runReplaceCommand(name) {
  if (!view || !codeMirrorSearch?.[name] || !currentFindQuery) return;
  if (!codeMirrorSearch[name](view)) return;
  const matches = codeMirrorFindMatches(currentFindQuery)?.matches ?? [];
  const after = view.state.selection.main.to;
  const index = name === "replaceNext" ? matches.findIndex((m) => m.from >= after) : 0;
  currentFindIndex = Math.max(0, index);
  post({ type: "replaceDone", index: currentFindIndex });
}

const replaceCommandNames = new Set(["replaceNext", "replaceAll"]);

// 行号 + 折叠列默认关（html 上预置 mp-hide-gutters，首帧不闪）；「…」里开
function setLineNumbers(visible) {
  const hidden = !visible;
  if (document.documentElement.classList.contains("mp-hide-gutters") === hidden) return;
  document.documentElement.classList.toggle("mp-hide-gutters", hidden);
  view?.requestMeasure();
}

// 字色跟 app 主题（深色模式也一致）；底色透明不注入
function applyColors(colors) {
  const root = document.documentElement.style;
  if (colors.text) root.setProperty("--mp-text", colors.text);
  if (colors.muted) root.setProperty("--mp-muted", colors.muted);
  if (colors.scheme) root.setProperty("color-scheme", colors.scheme);
}

window.memoryPalaceNative = {
  receive(payload) {
    if (!payload) return;
    if (payload.type === "setContent") {
      setEditorContent(
        payload.content ?? "",
        Number.isInteger(payload.revision) ? payload.revision : null
      );
      if (typeof payload.lineNumbers === "boolean") setLineNumbers(payload.lineNumbers);
      if (payload.colors) applyColors(payload.colors);
      const pendingCommand = payload.command && payload.command.token !== lastCommandToken ? payload.command : null;
      const replacing = pendingCommand && replaceCommandNames.has(pendingCommand.name);
      if (payload.find) {
        currentReplaceText = payload.find.replace ?? "";
        const query = payload.find.query ?? "";
        const index = payload.find.index ?? 0;
        // 每次打字 Swift 都会带着同一个查找词回推一遍；查找词 / 序号没变就不重新选中命中处，
        // 不然查找词还在时一打字光标就被拽回命中处。替换前必须重新选中当前项
        const findKey = `${query}\u0000${index}\u0000${currentReplaceText}`;
        if (findKey !== lastFindKey || replacing) {
          lastFindKey = findKey;
          applyFind(query, index);
        }
      } else if (currentFindQuery) {
        applyFind(currentFindQuery, currentFindIndex);
      }
      if (pendingCommand) {
        lastCommandToken = payload.command.token;
        // 替换不抢焦点（键盘留在查找/替换输入框）；格式命令执行完会 focus 回编辑器
        if (replaceCommandNames.has(payload.command.name)) runReplaceCommand(payload.command.name);
        else runMarkdownCommand(payload.command.name);
      }
    } else if (payload.type === "find") {
      applyFind(payload.query ?? "", payload.index ?? 0);
    } else if (payload.type === "command" && payload.token !== lastCommandToken) {
      lastCommandToken = payload.token;
      runMarkdownCommand(payload.name);
    }
  },
  focus() {
    if (view) view.focus();
    else fallbackTextArea?.focus();
  }
};

window.addEventListener("error", (event) => {
  post({
    type: "error",
    message: event.message || "编辑器脚本错误"
  });
});

const livePreviewDecorationCache = new Map();

function livePreviewDeco(Decoration, kind, className) {
  const key = kind + ":" + (className || "");
  let deco = livePreviewDecorationCache.get(key);
  if (!deco) {
    if (kind === "line") deco = Decoration.line({ class: className });
    else if (kind === "hide") deco = Decoration.replace({});
    else deco = Decoration.mark({ class: className });
    livePreviewDecorationCache.set(key, deco);
  }
  return deco;
}

function collectInlineDecorations(lineText, lineFrom, isActiveLine, Decoration, out) {
  const occupied = [];
  const overlaps = (from, to) => occupied.some((r) => from < r.to && to > r.from);
  const pushMark = (from, to, className) => {
    out.push({ from, to, deco: livePreviewDeco(Decoration, "mark", className) });
  };
  // 非光标行隐藏 Markdown 标记，光标行显示完整源码（Obsidian Live Preview 式）
  const pushHide = (from, to) => {
    out.push({ from, to, deco: livePreviewDeco(Decoration, "hide") });
  };

  // inline code 先扫并占位，避免 code span 里的 ** / [] 被当作粗体和链接
  const codeRe = /`([^`\n]+)`/g;
  let m;
  while ((m = codeRe.exec(lineText))) {
    const start = lineFrom + m.index;
    const end = start + m[0].length;
    occupied.push({ from: start, to: end });
    if (!isActiveLine) {
      pushHide(start, start + 1);
      pushHide(end - 1, end);
    }
    pushMark(start + 1, end - 1, "mp-md-inline-code");
  }

  const boldRe = /\*\*([^*\n]+)\*\*/g;
  while ((m = boldRe.exec(lineText))) {
    const start = lineFrom + m.index;
    const end = start + m[0].length;
    if (overlaps(start, end)) continue;
    occupied.push({ from: start, to: end });
    if (!isActiveLine) {
      pushHide(start, start + 2);
      pushHide(end - 2, end);
    }
    pushMark(start + 2, end - 2, "mp-md-strong");
  }

  // [[wiki link]]：内容渲染链接药丸（带 data-wiki 供点击跳转），非光标行隐藏括号
  const wikiRe = /\[\[([^\[\]\n]+)\]\]/g;
  while ((m = wikiRe.exec(lineText))) {
    const start = lineFrom + m.index;
    const end = start + m[0].length;
    if (overlaps(start, end)) continue;
    occupied.push({ from: start, to: end });
    if (!isActiveLine) {
      pushHide(start, start + 2);
      pushHide(end - 2, end);
    }
    out.push({
      from: start + 2,
      to: end - 2,
      deco: Decoration.mark({ class: "mp-md-wiki-link", attributes: { "data-wiki": m[1] } })
    });
  }

  const linkRe = /\[([^\]\n]+)\]\(([^)\n]+)\)/g;
  while ((m = linkRe.exec(lineText))) {
    const start = lineFrom + m.index;
    const end = start + m[0].length;
    if (overlaps(start, end)) continue;
    occupied.push({ from: start, to: end });
    const textStart = start + 1;
    const textEnd = textStart + m[1].length;
    pushMark(textStart, textEnd, "mp-md-link-text");
    if (!isActiveLine) {
      // 渲染态只留可点击观感的链接文字，[ 和 ](url) 整段收起
      pushHide(start, textStart);
      pushHide(textEnd, end);
    } else {
      const urlStart = textEnd + 2;
      const urlEnd = urlStart + m[2].length;
      pushMark(urlStart, urlEnd, "mp-md-link-url");
    }
  }
}

function buildMarkdownPreviewDecorations(view, Decoration, RangeSetBuilder, taskWidgets) {
  const builder = new RangeSetBuilder();
  const doc = view.state.doc;
  // 选区碰到的行全部还原源码（跨行拖选时和 Obsidian 一致）
  const selection = view.state.selection.main;
  const activeFromLine = doc.lineAt(selection.from).number;
  const activeToLine = doc.lineAt(selection.to).number;
  const headingRe = /^(#{1,3})(\s+)\S/;
  const taskRe = /^(\s*)([-*+]\s+\[([ xX])\])(\s)/;
  const quoteRe = /^((?:\s*>\s?)+)/;
  const frontmatter = docFrontmatterRange(doc);

  for (const range of view.visibleRanges) {
    // fence 状态从可视范围起点起算；长代码块只露下半截时会判错，spike 接受
    let inCodeBlock = false;
    let pos = range.from;
    while (pos <= range.to) {
      const line = doc.lineAt(pos);
      const text = line.text;
      const isActiveLine = line.number >= activeFromLine && line.number <= activeToLine;
      const marks = [];

      if (frontmatter && line.from <= frontmatter.to) {
        // 头部归 frontmatter 块管（卡片 / 源码态），字段值里的 [[x]]、**x** 不当正文美化
      } else if (/^```/.test(text)) {
        builder.add(line.from, line.from, livePreviewDeco(Decoration, "line", "mp-md-codeblock-line"));
        inCodeBlock = !inCodeBlock;
      } else if (inCodeBlock) {
        builder.add(line.from, line.from, livePreviewDeco(Decoration, "line", "mp-md-codeblock-line"));
      } else {
        const task = taskRe.exec(text);
        const heading = task ? null : headingRe.exec(text);
        const quote = task || heading ? null : quoteRe.exec(text);
        if (task) {
          if (task[3] !== " ") {
            builder.add(line.from, line.from, livePreviewDeco(Decoration, "line", "mp-md-task-done"));
          }
          if (!isActiveLine && taskWidgets) {
            marks.push({
              from: line.from + task[1].length,
              to: line.from + task[1].length + task[2].length + 1,
              deco: task[3] === " " ? taskWidgets.unchecked : taskWidgets.checked
            });
          }
        } else if (heading) {
          const level = heading[1].length;
          builder.add(
            line.from,
            line.from,
            livePreviewDeco(Decoration, "line", `mp-md-heading-line mp-md-heading-${level}`)
          );
          if (!isActiveLine) {
            marks.push({
              from: line.from,
              to: line.from + level + heading[2].length,
              deco: livePreviewDeco(Decoration, "hide")
            });
          }
        } else if (quote) {
          builder.add(line.from, line.from, livePreviewDeco(Decoration, "line", "mp-md-quote-line"));
          if (!isActiveLine) {
            marks.push({
              from: line.from,
              to: line.from + quote[1].length,
              deco: livePreviewDeco(Decoration, "hide")
            });
          }
        }
        collectInlineDecorations(text, line.from, isActiveLine, Decoration, marks);
      }

      marks.sort((a, b) => a.from - b.from || a.to - b.to);
      for (const mark of marks) {
        if (mark.from < mark.to) builder.add(mark.from, mark.to, mark.deco);
      }

      if (line.to >= range.to) break;
      pos = line.to + 1;
    }
  }
  return builder.finish();
}

// ── frontmatter（文件开头 `---` 包起来的 YAML 头）
// 解析口径与 Swift `MarkdownFrontmatter`（Utils/MarkdownFrontmatter.swift，阅读模式 / 文件列表在用）逐条一致，
// 改一边必须改另一边；用例同 MarkdownFrontmatterTests，node 跑 scripts/web-tests/frontmatter_test.mjs

// 只修空格 / 制表符（Swift `.whitespaces`），不碰换行
function trimFrontmatterSpaces(text) {
  return text.replace(/^[^\S\r\n]+|[^\S\r\n]+$/g, "");
}

// 必须 `---\n` 开头；收尾是单独一行 `---`（`----` / `--- foo` 不算，正文里的分隔线不能当收尾）；没收尾 → null。
// 返回头部正文 [headFrom, headTo) 和收尾 `---` 的结束位置 closeTo（不含其后换行）
function frontmatterBounds(md) {
  if (!md.startsWith("---\n")) return null;
  let searchFrom = 4;
  for (;;) {
    const hit = md.indexOf("\n---", searchFrom);
    if (hit < 0) return null;
    const after = hit + 4;
    if (after === md.length || md[after] === "\n") return { headFrom: 4, headTo: hit, closeTo: after };
    searchFrom = after;
  }
}

// 去掉包裹引号（含中文引号）、行内数组 `[a, b]` 摊成「a、b」
function cleanFrontmatterValue(raw) {
  let value = raw;
  if (value.length >= 2 && value.startsWith("[") && value.endsWith("]")) {
    return value
      .slice(1, -1)
      .split(",")
      .filter((part) => part !== "")
      .map((part) => cleanFrontmatterValue(trimFrontmatterSpaces(part)))
      .join("、");
  }
  for (const quote of ["\"", "'", "“"]) {
    if (value.startsWith(quote)) value = value.slice(1);
  }
  for (const quote of ["\"", "'", "”"]) {
    if (value.endsWith(quote)) value = value.slice(0, -1);
  }
  return value;
}

// 保序；缩进 / `- item` 续行并进上一个字段；认不出的行忽略
function frontmatterFields(head) {
  const out = [];
  for (const line of head.split("\n")) {
    const trimmed = trimFrontmatterSpaces(line);
    if (!trimmed) continue;
    if (line[0] === " " || line[0] === "\t" || trimmed.startsWith("- ")) {
      const item = cleanFrontmatterValue(trimFrontmatterSpaces(trimmed.replace(/^-+/, "")));
      if (!item || !out.length) continue;
      const last = out.pop();
      out.push({ key: last.key, value: last.value ? last.value + "、" + item : item });
      continue;
    }
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const key = trimFrontmatterSpaces(line.slice(0, colon));
    if (!key) continue;
    out.push({ key, value: cleanFrontmatterValue(trimFrontmatterSpaces(line.slice(colon + 1))) });
  }
  return out;
}

function splitFrontmatter(md) {
  const bounds = frontmatterBounds(md);
  if (!bounds) return { fields: [], body: md };
  return {
    fields: frontmatterFields(md.slice(bounds.headFrom, bounds.headTo)),
    body: md.slice(bounds.closeTo).trim()
  };
}

// 编辑器里的头部范围 [0, to]（to = 收尾 `---` 行尾）。逐行找、不拼整篇字符串；
// 与 frontmatterBounds 等价：首行 `---`，收尾最早在第 3 行（`---\n---` 不算头，同 Swift）
function docFrontmatterRange(doc) {
  if (doc.lines < 3 || doc.line(1).text !== "---") return null;
  for (let n = 3; n <= doc.lines; n += 1) {
    const line = doc.line(n);
    if (line.text === "---") return { to: line.to };
  }
  return null;
}

// lezer 块扩展：不加的话开头 `---` 是分割线、字段区 + 收尾 `---` 被当 setext 二级标题（粗体大字）
function frontmatterMarkdownExtension(tags) {
  return {
    defineNodes: [{ name: "Frontmatter", block: true, style: tags.meta }],
    parseBlock: [
      {
        name: "Frontmatter",
        before: "HorizontalRule",
        parse(cx, line) {
          if (cx.lineStart !== 0 || line.text !== "---") return false;
          // 先确认有收尾再吃行：没收尾的 `---` 照旧当分割线，不能把整篇吞掉
          const bounds = frontmatterBounds(cx.input.read(0, cx.input.length));
          if (!bounds) return false;
          const closeFrom = bounds.closeTo - 3;
          while (cx.nextLine()) {
            if (cx.lineStart === closeFrom) {
              cx.addElement(cx.elt("Frontmatter", 0, bounds.closeTo));
              cx.nextLine();
              return true;
            }
          }
          return false;
        }
      }
    ]
  };
}

// 属性卡走 StateField（块级 replace 不能由 ViewPlugin 提供，同表格块）。外观照阅读模式的 FrontmatterCard。
// 打开文件时光标在位置 0 = 头部里：只有用户把选区放进头部（点击 / 方向键 / 查找命中 / 输入）才露源码，
// native setContent 整篇替换和初始创建不算，所以打开时出卡
function createMarkdownFrontmatterExtension({ Decoration, EditorView, RangeSetBuilder, StateField, WidgetType }) {
  class FrontmatterWidget extends WidgetType {
    constructor(fields) {
      super();
      this.fields = fields;
      this.signature = JSON.stringify(fields);
    }

    eq(other) {
      return other.signature === this.signature;
    }

    toDOM() {
      // 键列宽度照 FrontmatterCard：按最长的键估，夹在 72...160
      const longest = Math.max(0, ...this.fields.map((field) => Array.from(field.key).length));
      const keyWidth = Math.min(160, Math.max(72, longest * 8 + 8));
      const card = document.createElement("div");
      card.className = "mp-md-frontmatter";
      for (const field of this.fields) {
        const row = document.createElement("div");
        row.className = "mp-md-frontmatter-row";
        const key = document.createElement("span");
        key.className = "mp-md-frontmatter-key";
        key.style.width = keyWidth + "px";
        key.textContent = field.key;
        const value = document.createElement("span");
        value.className = "mp-md-frontmatter-value";
        value.textContent = field.value;
        row.append(key, value);
        card.appendChild(row);
      }
      return card;
    }

    ignoreEvent() {
      return false;
    }
  }

  const sourceLine = Decoration.line({ class: "mp-md-frontmatter-line" });

  function buildFrontmatterState(state, revealed) {
    const builder = new RangeSetBuilder();
    const range = docFrontmatterRange(state.doc);
    if (!range) return { revealed: false, decorations: builder.finish() };
    const fields = splitFrontmatter(state.doc.sliceString(0, range.to)).fields;
    const inside = state.selection.main.from <= range.to;
    const showSource = inside && revealed;
    // 字段一个都认不出：不出空卡，直接露源码（还能点进去改）
    if (fields.length && !showSource) {
      builder.add(0, range.to, Decoration.replace({ widget: new FrontmatterWidget(fields), block: true }));
    } else {
      let line = state.doc.line(1);
      for (;;) {
        builder.add(line.from, line.from, sourceLine);
        if (line.to >= range.to) break;
        line = state.doc.line(line.number + 1);
      }
    }
    return { revealed: showSource, decorations: builder.finish() };
  }

  return StateField.define({
    create(state) {
      return buildFrontmatterState(state, false);
    },
    update(value, tr) {
      if (!tr.docChanged && !tr.selection) return value;
      const userPlaced =
        tr.selection !== undefined ||
        tr.isUserEvent("input") ||
        tr.isUserEvent("delete") ||
        tr.isUserEvent("undo") ||
        tr.isUserEvent("redo");
      return buildFrontmatterState(tr.state, value.revealed || userPlaced);
    },
    provide: (field) => EditorView.decorations.from(field, (value) => value.decorations)
  });
}

function parseTableCells(rowText) {
  const trimmed = rowText.trim().replace(/^\|/, "").replace(/\|$/, "");
  return trimmed.split("|").map((cell) => cell.trim());
}

const tableRowRe = /^\s*\|.*\|\s*$/;
const tableSeparatorRe = /^\s*\|(?:\s*:?-+:?\s*\|)+\s*$/;

// 表格块渲染走 StateField：CodeMirror 规定影响块结构的 replace decoration
// 不能由 ViewPlugin 提供。全文扫描（含 fence 跟踪），表格少、文件小，每次编辑重算可接受。
function createMarkdownTableExtension({ Decoration, EditorView, RangeSetBuilder, StateField, WidgetType }) {
  class MarkdownTableWidget extends WidgetType {
    constructor(source) {
      super();
      this.source = source;
    }

    eq(other) {
      return other.source === this.source;
    }

    toDOM() {
      const lines = this.source.split("\n");
      const header = parseTableCells(lines[0]);
      const table = document.createElement("table");
      table.className = "mp-md-table";
      const thead = table.createTHead();
      const headRow = thead.insertRow();
      for (const cell of header) {
        const th = document.createElement("th");
        th.textContent = cell;
        headRow.appendChild(th);
      }
      const tbody = table.createTBody();
      for (const line of lines.slice(2)) {
        const row = tbody.insertRow();
        for (const cell of parseTableCells(line)) {
          row.insertCell().textContent = cell;
        }
      }
      const wrap = document.createElement("div");
      wrap.className = "mp-md-table-widget";
      wrap.appendChild(table);
      return wrap;
    }

    ignoreEvent() {
      return false;
    }
  }

  function buildTableDecorations(state) {
    const builder = new RangeSetBuilder();
    const doc = state.doc;
    const selection = state.selection.main;
    const activeFromLine = doc.lineAt(selection.from).number;
    const activeToLine = doc.lineAt(selection.to).number;
    let inCodeBlock = false;
    // 从 frontmatter 之后扫：两个块级 replace 不能叠在一起
    const frontmatter = docFrontmatterRange(doc);
    let lineNo = frontmatter ? doc.lineAt(frontmatter.to).number + 1 : 1;

    while (lineNo <= doc.lines) {
      const line = doc.line(lineNo);
      if (/^```/.test(line.text)) {
        inCodeBlock = !inCodeBlock;
        lineNo += 1;
        continue;
      }
      if (inCodeBlock || !tableRowRe.test(line.text)) {
        lineNo += 1;
        continue;
      }
      if (lineNo + 1 > doc.lines || !tableSeparatorRe.test(doc.line(lineNo + 1).text)) {
        lineNo += 1;
        continue;
      }
      let endLineNo = lineNo + 1;
      while (endLineNo + 1 <= doc.lines && tableRowRe.test(doc.line(endLineNo + 1).text)) {
        endLineNo += 1;
      }
      const cursorInside = activeFromLine <= endLineNo && activeToLine >= lineNo;
      if (!cursorInside) {
        const endLine = doc.line(endLineNo);
        builder.add(
          line.from,
          endLine.to,
          Decoration.replace({
            widget: new MarkdownTableWidget(doc.sliceString(line.from, endLine.to)),
            block: true
          })
        );
      }
      lineNo = endLineNo + 1;
    }
    return builder.finish();
  }

  return StateField.define({
    create(state) {
      return buildTableDecorations(state);
    },
    update(value, tr) {
      if (tr.docChanged || tr.selection) return buildTableDecorations(tr.state);
      return value;
    },
    provide: (field) => EditorView.decorations.from(field)
  });
}

function toggleTaskCheckbox(view, pos) {
  const line = view.state.doc.lineAt(pos);
  const m = /^(\s*[-*+]\s+\[)([ xX])\]/.exec(line.text);
  if (!m) return false;
  const charPos = line.from + m[1].length;
  view.dispatch({
    changes: { from: charPos, to: charPos + 1, insert: m[2] === " " ? "x" : " " }
  });
  return true;
}

function createMarkdownLivePreviewExtension({ Decoration, ViewPlugin, RangeSetBuilder, WidgetType }) {
  class TaskCheckboxWidget extends WidgetType {
    constructor(checked) {
      super();
      this.checked = checked;
    }

    eq(other) {
      return other.checked === this.checked;
    }

    toDOM() {
      const box = document.createElement("input");
      box.type = "checkbox";
      box.className = "mp-md-task-checkbox";
      box.checked = this.checked;
      return box;
    }

    ignoreEvent() {
      return false;
    }
  }

  const taskWidgets = {
    checked: Decoration.replace({ widget: new TaskCheckboxWidget(true) }),
    unchecked: Decoration.replace({ widget: new TaskCheckboxWidget(false) })
  };

  return ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = buildMarkdownPreviewDecorations(view, Decoration, RangeSetBuilder, taskWidgets);
      }

      update(update) {
        if (update.docChanged || update.viewportChanged || update.selectionSet) {
          this.decorations = buildMarkdownPreviewDecorations(update.view, Decoration, RangeSetBuilder, taskWidgets);
        }
      }
    },
    {
      decorations: (plugin) => plugin.decorations,
      eventHandlers: {
        mousedown(event, view) {
          const target = event.target;
          if (target && target.nodeName === "INPUT" && target.classList.contains("mp-md-task-checkbox")) {
            return toggleTaskCheckbox(view, view.posAtDOM(target));
          }
          // 点 wiki link → 交 Swift 跳转/建文件
          const wiki = target && target.closest ? target.closest(".mp-md-wiki-link") : null;
          if (wiki && wiki.dataset && wiki.dataset.wiki) {
            post({ type: "openWikiLink", target: wiki.dataset.wiki });
            return true;
          }
          // 点渲染态表格 → 光标落进表格块还原源码编辑
          const tableWidget = target && target.closest ? target.closest(".mp-md-table-widget") : null;
          if (tableWidget) {
            view.dispatch({ selection: { anchor: view.posAtDOM(tableWidget) } });
            view.focus();
            return true;
          }
          // 点属性卡 → 露源码，光标放到第一个字段（第 2 行行首）
          const frontmatterCard = target && target.closest ? target.closest(".mp-md-frontmatter") : null;
          if (frontmatterCard) {
            view.dispatch({ selection: { anchor: view.state.doc.line(2).from }, userEvent: "select.pointer" });
            view.focus();
            return true;
          }
          return false;
        }
      }
    }
  );
}

async function upgradeToCodeMirror() {
  try {
    // bundle 是 IIFE 经典脚本挂的全局：WKWebView 的 file:// 下 ES module import
    // 会被 CORS（Origin null）拒掉，动态 import 在 app 内永远走不通
    if (!window.MPCodeMirror) throw new Error("MPCodeMirror bundle 未加载");
    const {
      Decoration,
      EditorView,
      RangeSetBuilder,
      StateField,
      ViewPlugin,
      WidgetType,
      basicSetup,
      keymap,
      markdown,
      HighlightStyle,
      SearchQuery,
      replaceAll,
      replaceNext,
      searchExtensions,
      setSearchQuery,
      syntaxHighlighting,
      tags
    } = window.MPCodeMirror;
    codeMirrorSearch = {
      SearchQuery,
      setSearchQuery,
      replaceNext,
      replaceAll
    };

    // 15px（10-02 实机：16px 和顶栏文件名一样大，显大）。防 iOS 聚焦自动放大（折行按放大前算、长行出屏，
    // research-file-editor-sheet §2）靠 html 的 viewport maximum-scale=1 + user-scalable=no，不靠字号 ≥ 16px。
    // 留白 / 行高也得写在 theme 里，CSS 文件里会被基础主题压掉。
    const memoryPalaceTheme = EditorView.theme({
      "&": {
        backgroundColor: "transparent",
        color: "var(--mp-text)",
        fontSize: "15px"
      },
      ".cm-scroller": {
        lineHeight: "1.6"
      },
      ".cm-content": {
        fontFamily: "-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif",
        padding: "16px 20px"
      },
      ".cm-line": {
        padding: "0 2px"
      },
      ".cm-activeLine": {
        backgroundColor: "rgba(231, 238, 236, 0.52)"
      },
      ".cm-gutters": {
        backgroundColor: "transparent",
        color: "var(--mp-muted)",
        borderRight: "1px solid rgba(207, 220, 216, 0.72)"
      },
      ".cm-cursor": {
        borderLeftColor: "#5f7f76"
      },
      "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
        backgroundColor: "rgba(95, 127, 118, 0.22)"
      }
    });

    const markdownHighlightStyle = HighlightStyle.define([
      { tag: tags.heading1, fontSize: "1.42em", fontWeight: "760", color: "var(--mp-text)" },
      { tag: tags.heading2, fontSize: "1.24em", fontWeight: "720", color: "var(--mp-text)" },
      { tag: tags.heading3, fontSize: "1.1em", fontWeight: "680", color: "var(--mp-text)" },
      { tag: tags.heading, fontWeight: "660", color: "var(--mp-text)" },
      { tag: tags.strong, fontWeight: "720", color: "var(--mp-text)" },
      { tag: tags.emphasis, fontStyle: "italic", color: "#58483d" },
      { tag: tags.link, color: "#56786f", textDecoration: "underline", textDecorationThickness: "1px" },
      { tag: tags.url, color: "#56786f" },
      { tag: tags.quote, color: "#67584f", fontStyle: "italic" },
      { tag: tags.monospace, color: "#4d625c", backgroundColor: "rgba(231, 238, 236, 0.58)" },
      { tag: tags.atom, color: "#6f635b" },
      { tag: tags.contentSeparator, color: "#9a8c83" },
      { tag: tags.processingInstruction, color: "var(--mp-muted)" },
      { tag: tags.meta, color: "var(--mp-muted)" }
    ]);

    content = currentContent();
    editorRoot.replaceChildren();
    view = new EditorView({
      doc: content,
      extensions: [
        // ⌘F 交给 Swift 的查找条：basicSetup 自带 searchKeymap 会弹 CodeMirror 英文面板。
        // 同优先级的 keymap 先注册先得，放在 basicSetup 前面就截得到，不用 Prec
        keymap.of([{ key: "Mod-f", run: () => { post({ type: "openFind" }); return true; } }]),
        basicSetup,
        markdown({ extensions: [frontmatterMarkdownExtension(tags)] }),
        searchExtensions,
        syntaxHighlighting(markdownHighlightStyle),
        createMarkdownLivePreviewExtension({ Decoration, ViewPlugin, RangeSetBuilder, WidgetType }),
        createMarkdownTableExtension({ Decoration, EditorView, RangeSetBuilder, StateField, WidgetType }),
        createMarkdownFrontmatterExtension({ Decoration, EditorView, RangeSetBuilder, StateField, WidgetType }),
        memoryPalaceTheme,
        EditorView.lineWrapping,
        keymap.of([
          { key: "Mod-b", run: markdownCommands.bold },
          { key: "Mod-i", run: markdownCommands.italic },
          { key: "Mod-`", run: markdownCommands.code },
          { key: "Mod-k", run: markdownCommands.link },
          { key: "Mod-Alt-1", run: markdownCommands.heading1 },
          { key: "Mod-Alt-2", run: markdownCommands.heading2 },
          { key: "Mod-Alt-3", run: markdownCommands.heading3 },
          { key: "Mod-Shift-7", run: markdownCommands.orderedList },
          { key: "Mod-Shift-8", run: markdownCommands.bulletList },
          { key: "Mod-Shift-9", run: markdownCommands.taskList },
          { key: "Mod-Shift-.", run: markdownCommands.quote },
          { key: "Enter", run: continueMarkdownList }
        ]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged && !applyingNativeUpdate) noteEditorChanged();
        }),
        EditorView.domEventHandlers({
          keydown(event) {
            if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
              event.preventDefault();
              requestSave();
              return true;
            }
            return false;
          },
          click(event) {
            const link = event.target.closest?.("a[href]");
            if (!link) return false;
            event.preventDefault();
            post({
              type: "openLink",
              href: link.href
            });
            return true;
          }
        })
      ],
      parent: editorRoot
    });

    fallbackTextArea = null;
    if (currentFindQuery) applyCodeMirrorFind(currentFindQuery, currentFindIndex);
  } catch {
    // Keep the fallback editor active. It is intentionally silent so the user
    // gets a usable editor even when the CodeMirror bundle cannot load.
  }
}

installFallbackEditor();
post({ type: "ready" });
upgradeToCodeMirror();
