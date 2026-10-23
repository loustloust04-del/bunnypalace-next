//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI
import Equatable

/// A source of incremental Markdown text for `StreamedMarkdownView`.
///
/// Each value yielded by `text` is a *complete snapshot* of the Markdown
/// source so far (a growing prefix), not an incremental delta. The view
/// re-parses each snapshot and updates the rendered output.
public protocol StreamedMarkdownSource {
  var text: AsyncStream<String> { get }
}

/// A SwiftUI view that incrementally parses and renders streamed Markdown.
///
/// Provide a `StreamedMarkdownSource` whose `text` async sequence yields
/// progressively larger snapshots of the Markdown source; the view re-parses
/// on each emission and refreshes the rendered output.
@Equatable
public struct StreamedMarkdownView: View {

  private let config: MarkdownRenderConfig
  @StateObject private var controller: StreamedMarkdownController

  /// Create a `StreamedMarkdownView`.
  /// - Parameters:
  ///   - source: The streamed Markdown source. Each emission must be the
  ///     complete Markdown source so far, not an incremental delta.
  ///   - config: Render configuration. Defaults to `.default`.
  ///   - listener: Optional listener that receives render and interaction events.
  public init(
    source: StreamedMarkdownSource,
    config: MarkdownRenderConfig = .default,
    listener: MarkdownListener? = nil
  ) {
    self.config = config
    _controller = StateObject(
      wrappedValue: StreamedMarkdownController(source: source, config: config, listener: listener)
    )
  }

  public var body: some View {
    DocumentView(
      renderableDocument: controller.markdownToRender,
      config: config,
      listener: controller.listener
    )
    .task {
      controller.updateConfig(config)
      controller.start()
    }
    .onChange(of: config) { newConfig in
      controller.updateConfig(newConfig)
    }
    #if !os(macOS)
    .onDisappear {
      controller.end()
    }
    #endif
  }
}

final class StreamedMarkdownController: ObservableObject {

  @Published var markdownToRender: RenderableDocument = .empty
  private var config: MarkdownRenderConfig
  let listener: MarkdownListener?

  private let source: StreamedMarkdownSource
  private let parser = MarkdownParserImpl()
  private var task: Task<Void, Never>?
  private var configTask: Task<Void, Never>?
  private var latestText: String?
  private var renderRevision = 0
  #if os(macOS) && L2E_HARNESS
  static var didInitialize: ((StreamedMarkdownController) -> Void)?
  var taskForHarness: Task<Void, Never>? { task }
  #endif
  #if os(macOS) && L2G_HARNESS
  @MainActor static var didParseForHarness: ((String, MarkdownRenderConfig) async -> Void)?
  #endif

  init(
    source: StreamedMarkdownSource,
    config: MarkdownRenderConfig,
    listener: MarkdownListener? = nil
  ) {
    self.source = source
    self.config = config
    self.listener = listener
    #if os(macOS) && L2E_HARNESS
    Self.didInitialize?(self)
    #endif
  }

  deinit {
    #if os(macOS)
    task?.cancel()
    #endif
    configTask?.cancel()
  }

  @MainActor
  func updateConfig(_ config: MarkdownRenderConfig) {
    guard self.config != config else { return }
    self.config = config
    guard let latestText else { return }
    let input = receive(latestText)
    let parser = self.parser
    configTask = Task { @MainActor [weak self] in
      let renderable = await parser.parse(text: latestText, config: input.config)
      #if os(macOS) && L2G_HARNESS
      await Self.didParseForHarness?(latestText, input.config)
      #endif
      if Task.isCancelled { return }
      self?.publish(renderable, revision: input.revision)
      self?.configTask = nil
    }
  }

  // Both input changes are ordered on the main actor; parsing stays asynchronous.
  @MainActor
  private func receive(_ text: String) -> (config: MarkdownRenderConfig, revision: Int) {
    latestText = text
    renderRevision += 1
    configTask?.cancel()
    return (config, renderRevision)
  }

  @MainActor
  private func publish(_ renderable: RenderableDocument, revision: Int) {
    guard revision == renderRevision else { return }
    markdownToRender = renderable
  }

  #if os(macOS)
  @MainActor
  func start() {
    guard task == nil else { return }
    let stream = source.text
    let parser = self.parser
    task = Task { @MainActor [weak self] in
      defer { self?.task = nil }
      for await text in stream {
        if Task.isCancelled { break }
        guard let input = self?.receive(text) else { break }
        let renderable = await parser.parse(text: text, config: input.config)
        #if L2G_HARNESS
        await Self.didParseForHarness?(text, input.config)
        #endif
        if Task.isCancelled { break }
        self?.publish(renderable, revision: input.revision)
      }
    }
  }

  @MainActor
  func end() {
    task?.cancel()
    configTask?.cancel()
  }
  #else
  @MainActor
  func start() {
    task?.cancel()
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      for await text in self.source.text {
        if Task.isCancelled { return }
        let input = self.receive(text)
        let renderable = await self.parser.parse(text: text, config: input.config)
        if Task.isCancelled { return }
        self.publish(renderable, revision: input.revision)
      }
    }
  }

  @MainActor
  func end() {
    task?.cancel()
    task = nil
    configTask?.cancel()
  }
  #endif
}
