import XCTest
import WidgetKit
import WokintoshCore

final class PhoneWidgetTests:XCTestCase {
    func testProviderArtworkResolvesInTheOwningResourceBundle() {
        for provider in ["codex", "claude", "antigravity", "opencode"] {
            XCTAssertNotNil(PhoneProviderArtwork.image(for: provider), provider)
        }
    }
    func testProviderArtworkFitsWidgetKitRasterBudgetWithoutChangingAspectRatio()throws {
        for name in ["PhoneCodex","PhoneClaude","PhoneAntigravity","PhoneOpenCode"] {
            let source=try XCTUnwrap(UIImage(named:name,in:Bundle(for:Self.self),compatibleWith:nil))
            let image=try XCTUnwrap(PhoneProviderArtwork.thumbnail(source))
            let raster=try XCTUnwrap(image.cgImage)
            XCTAssertLessThanOrEqual(raster.width,66)
            XCTAssertLessThanOrEqual(raster.height,66)
            XCTAssertEqual(Double(raster.width)/Double(raster.height),Double(source.size.width/source.size.height),accuracy:0.02)
        }
    }
    func testAdditionalProviderArtworkUsesDistinctDarkVariantAndNeutralUnknownFallback() throws {
        let light = try XCTUnwrap(PhoneProviderArtwork.image(for: "opencode", dark: false))
        let dark = try XCTUnwrap(PhoneProviderArtwork.image(for: "opencode", dark: true))
        XCTAssertNotEqual(light.pngData(), dark.pngData())
        XCTAssertNotNil(PhoneProviderArtwork.image(for: "antigravity"))
        XCTAssertNil(PhoneProviderArtwork.image(for: "future-provider"))
    }
    func testWideAndTallFamiliesUseTheMatchingPresentation() {
        XCTAssertEqual(AgentWidgetLayout.size(for:.systemExtraLarge),.extraLarge)
        XCTAssertTrue(AgentWidgetLayout.supportedFamilies.contains(.systemExtraLarge))
        if #available(iOS 27.0,*) {
            XCTAssertEqual(AgentWidgetLayout.size(for:.systemExtraLargePortrait),.extraLargePortrait)
            XCTAssertTrue(AgentWidgetLayout.supportedFamilies.contains(.systemExtraLargePortrait))
        }
    }
    func testSelectionIncludesPublisherAndDoesNotFallBackToAnotherWidget() {
        let feed=PhoneFixtures.feed(),snapshot=PhoneSnapshot(feed:feed,state:.current,lastFetchedAt:Date(),paired:true)
        let selected=AgentWidgetEntry.scopedID(publisher:feed.publisherID,widget:feed.widgets[0].id)
        XCTAssertEqual(AgentWidgetEntry.make(snapshot:snapshot,selection:selected,at:Date()).widget?.id,feed.widgets[0].id)
        let wrong=AgentWidgetEntry.scopedID(publisher:UUID(),widget:feed.widgets[0].id)
        XCTAssertNil(AgentWidgetEntry.make(snapshot:snapshot,selection:wrong,at:Date()).widget)
        XCTAssertEqual(AgentWidgetEntry.make(snapshot:snapshot,selection:nil,at:Date()).widget?.id,feed.widgets[0].id)
    }


}
