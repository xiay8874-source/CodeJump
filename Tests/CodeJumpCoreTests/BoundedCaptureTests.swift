import Testing
import Foundation
@testable import CodeJumpCore

private actor CaptureFixture {
    var reads = 0
    var current = true
    let usefulAfter: Int
    let changeAfterRead: Bool
    init(usefulAfter: Int, changeAfterRead: Bool = false) {
        self.usefulAfter = usefulAfter; self.changeAfterRead = changeAfterRead
    }
    func capture() -> String {
        reads += 1
        if changeAfterRead { current = false }
        return reads >= usefulAfter ? "RecordHelper.addBatch2RecordAndAddressLock" : ""
    }
}

struct BoundedCaptureTests {
    @Test func coldFirstReadRecoversWithinOneGesture() async {
        let fixture = CaptureFixture(usefulAfter: 2)
        let result = await BoundedCapture.read(delay: .zero, targetIsCurrent: { await fixture.current },
            capture: { await fixture.capture() }, isUseful: { !$0.isEmpty })
        #expect(result?.attempts == 2)
        #expect(result?.value == "RecordHelper.addBatch2RecordAndAddressLock")
        #expect(await fixture.reads == 2)
    }
    @Test func warmReadIsNotRepeated() async {
        let fixture = CaptureFixture(usefulAfter: 1)
        let result = await BoundedCapture.read(delay: .zero, targetIsCurrent: { await fixture.current },
            capture: { await fixture.capture() }, isUseful: { !$0.isEmpty })
        #expect(result?.attempts == 1)
        #expect(await fixture.reads == 1)
    }
    @Test func unavailableTextStopsAtBound() async {
        let fixture = CaptureFixture(usefulAfter: 99)
        let result = await BoundedCapture.read(delay: .zero, targetIsCurrent: { await fixture.current },
            capture: { await fixture.capture() }, isUseful: { !$0.isEmpty })
        #expect(result?.attempts == 3)
        #expect(result?.value == "")
        #expect(await fixture.reads == 3)
    }
    @Test func changedTargetCannotReturnStaleText() async {
        let fixture = CaptureFixture(usefulAfter: 1, changeAfterRead: true)
        let result = await BoundedCapture.read(delay: .zero, targetIsCurrent: { await fixture.current },
            capture: { await fixture.capture() }, isUseful: { !$0.isEmpty })
        #expect(result == nil)
        #expect(await fixture.reads == 1)
    }
    @Test func cancelledGestureDoesNotRead() async {
        let fixture = CaptureFixture(usefulAfter: 2)
        let task = Task {
            await BoundedCapture.read(delay: .seconds(1), targetIsCurrent: { await fixture.current },
                capture: { await fixture.capture() }, isUseful: { !$0.isEmpty })
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
        #expect(await fixture.reads <= 1)
    }
}
