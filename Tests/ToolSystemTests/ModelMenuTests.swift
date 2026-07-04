// Tests for the two-level /model menu parser grammar and static menu builders.
// These tests avoid touching ~/.mlx-coder or the network — they exercise pure
// parsing and the root/provider menu shapes (provider list comes from the
// user's configured providers in ~/.mlx-coder/config.json).

import XCTest
import SwiftCoderTUI
@testable import MLXCoder

final class ModelMenuTests: XCTestCase {
    private let models: [AppConfig.ModelConfig] = [
        AppConfig.ModelConfig(id: "owner/local-a", label: "owner/local-a"),
        AppConfig.ModelConfig(id: "owner/local-b", label: "owner/local-b")
    ]

    func testBareModelOpensRootMenu() {
        XCTAssertEqual(TUIModelCommandParser.resolve(input: "/model", models: models), .openRootMenu)
    }

    func testLocalOpensLocalMenu() {
        XCTAssertEqual(TUIModelCommandParser.resolve(input: "/model local", models: models), .openLocalMenu)
    }

    func testLocalWithIDSelectsLocal() {
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model local owner/name", models: models),
            .selectLocal(id: "owner/name")
        )
    }

    func testRemoteOpensProvidersMenu() {
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model remote", models: models),
            .openRemoteProvidersMenu
        )
    }

    func testRemoteProviderOpensModelsMenu() {
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model remote openrouter", models: models),
            .openRemoteModelsMenu(provider: "openrouter")
        )
    }

    func testRemoteProviderRefresh() {
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model remote openrouter refresh", models: models),
            .refreshRemote(provider: "openrouter")
        )
    }

    func testRemoteProviderModelSelect() {
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model remote openrouter anthropic/claude-sonnet-4.5", models: models),
            .selectRemote(provider: "openrouter", modelID: "anthropic/claude-sonnet-4.5")
        )
    }

    func testFilterVerbsReturnNil() {
        XCTAssertNil(TUIModelCommandParser.resolve(input: "/model free", models: models))
        XCTAssertNil(TUIModelCommandParser.resolve(input: "/model all", models: models))
        XCTAssertNil(TUIModelCommandParser.resolve(input: "/model reset", models: models))
    }

    func testNumericSelectsExisting() {
        XCTAssertEqual(TUIModelCommandParser.resolve(input: "/model 2", models: models), .selectExisting(index: 1))
    }

    func testLabelSelectsExisting() {
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model owner/local-a", models: models),
            .selectExisting(index: 0)
        )
    }

    func testUnknownIsInvalid() {
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model nope/nope", models: models),
            .invalidModelName("nope/nope")
        )
    }

    func testSinglePartialMatchSelectsExisting() {
        let list = [
            AppConfig.ModelConfig(id: "qwen/qwen3-coder", label: "qwen/qwen3-coder"),
            AppConfig.ModelConfig(id: "meta/llama-3", label: "meta/llama-3")
        ]
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model coder", models: list),
            .selectExisting(index: 0)
        )
    }

    func testMultiplePartialMatchesOpenFilteredMenu() {
        let list = [
            AppConfig.ModelConfig(id: "qwen/qwen3-coder", label: "qwen/qwen3-coder"),
            AppConfig.ModelConfig(id: "openrouter:qwen/qwen2.5-coder", label: "openrouter:qwen/qwen2.5-coder"),
            AppConfig.ModelConfig(id: "meta/llama-3", label: "meta/llama-3")
        ]
        XCTAssertEqual(
            TUIModelCommandParser.resolve(input: "/model coder", models: list),
            .openFilteredMenu(query: "coder")
        )
    }

    func testFilteredMenuItemsListMatches() {
        let list = [
            AppConfig.ModelConfig(id: "qwen/qwen3-coder", label: "qwen/qwen3-coder"),
            AppConfig.ModelConfig(id: "openrouter:qwen/qwen2.5-coder", label: "openrouter:qwen/qwen2.5-coder"),
            AppConfig.ModelConfig(id: "meta/llama-3", label: "meta/llama-3")
        ]
        let items = TUIModelCommandParser.filteredMenuItems(query: "coder", models: list, currentModelLabel: "")
        XCTAssertEqual(items.map(\.name), [
            "/model qwen/qwen3-coder",
            "/model openrouter:qwen/qwen2.5-coder"
        ])
    }

    func testNonModelReturnsNil() {
        XCTAssertNil(TUIModelCommandParser.resolve(input: "/effort high", models: models))
    }

    func testRootMenuItems() {
        let items = TUIModelCommandParser.rootMenuItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "/model local")
        XCTAssertEqual(items[1].name, "/model remote")
    }

    func testRemoteProvidersMenuMirrorsConfiguredProviders() {
        // The menu lists exactly the providers configured in ~/.mlx-coder/config.json
        // (no built-ins), one row per provider.
        let providers = RemoteProviderRegistry.providers()
        let items = TUIModelCommandParser.remoteProvidersMenuItems()
        XCTAssertEqual(items.count, providers.count)
        for provider in providers {
            XCTAssertTrue(items.contains { $0.name == "/model remote \(provider.id)" })
        }
    }
}
