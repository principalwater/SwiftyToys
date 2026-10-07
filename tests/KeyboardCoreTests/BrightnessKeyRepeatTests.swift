// SPDX-License-Identifier: MIT

import KeyboardCore
import Testing

struct BrightnessKeyRepeatTests {
    @Test func heldKeysRepeatOnceAndReleaseOrCancellationStopsThem() {
        var repeatKeys = BrightnessKeyRepeat(delayMs: 400, intervalMs: 60)
        #expect(repeatKeys.update(source: -1, keys: 2, time: 100) == 1)
        #expect(repeatKeys.update(source: -1, keys: 2, time: 200) == 0)
        #expect(repeatKeys.update(source: 4, keys: 2, time: 250) == 0)
        #expect(repeatKeys.tick(time: 499) == 0)
        #expect(repeatKeys.tick(time: 500) == 1)
        #expect(repeatKeys.tick(time: 559) == 0)
        #expect(repeatKeys.tick(time: 560) == 1)
        #expect(repeatKeys.tick(time: 5000) == 1)
        #expect(repeatKeys.tick(time: 5000) == 0)
        #expect(repeatKeys.update(source: -1, keys: 0, time: 5001) == 0)
        #expect(repeatKeys.isHeld)
        #expect(repeatKeys.update(source: 4, keys: 0, time: 5002) == 0)
        #expect(repeatKeys.tick(time: 6000) == 0)
        #expect(repeatKeys.isHeld == false)

        #expect(repeatKeys.update(source: -1, keys: 1, time: 7000) == -1)
        #expect(repeatKeys.update(source: 4, keys: 2, time: 7001) == 0)
        #expect(repeatKeys.tick(time: 7500) == 0)
        #expect(repeatKeys.update(source: 4, keys: 0, time: 7501) == -1)
        repeatKeys.cancel()
        #expect(repeatKeys.tick(time: 8000) == 0)
        #expect(repeatKeys.update(source: -1, keys: 3, time: 8001) == 0)
        #expect(repeatKeys.update(source: -1, keys: 2, time: 8002) == 0)
        #expect(repeatKeys.update(source: -1, keys: 0, time: 8003) == 0)
        #expect(repeatKeys.update(source: -1, keys: 2, time: 8004) == 1)
        repeatKeys.reset()
        #expect(repeatKeys.tick(time: 9000) == 0)
        #expect(repeatKeys.update(source: -2, keys: 1, time: 9001) == -1)
        #expect(repeatKeys.update(source: 8, keys: 255, time: 9002) == 0)
        #expect(repeatKeys.tick(time: 9401) == -1)
    }
}
