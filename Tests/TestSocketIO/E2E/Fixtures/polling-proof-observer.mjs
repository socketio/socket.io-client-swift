// One observation deadline, one active GET. A timeout is terminal: abort and
// await the current request (including its body) before returning to the caller.
// Retrying a Promise.race timeout would leave the losing GET active and could
// itself close the Engine.IO session, invalidating a no-ack proof.
/**
 * Collect successful polling bodies sequentially until complete or timed out.
 * @param {(signal: AbortSignal) => Promise<Response>} poll One abortable GET.
 * @param {(frames: string[]) => boolean} isComplete Observation predicate.
 * @param {number} timeoutMs Overall deadline, including response body reads.
 * @returns {Promise<{frames: string[], timedOut: boolean, terminalStatus?: number}>}
 */
export async function observePolling(poll, isComplete, timeoutMs = 1500) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new RangeError("timeoutMs must be a finite positive number")
  }
  const controller = new AbortController()
  const timeoutError = new Error("polling observation timed out")
  const timer = setTimeout(() => controller.abort(timeoutError), timeoutMs)
  const frames = []
  try {
    while (!isComplete(frames)) {
      if (controller.signal.aborted) return { frames, timedOut: true }
      const response = await poll(controller.signal)
      if (response.status !== 200) {
        // A rejected oversized POST may terminate the server's session. Record
        // that status, consume its body, and stop rather than spinning on 400s.
        await response.text()
        return { frames, timedOut: false, terminalStatus: response.status }
      }
      frames.push(await response.text())
    }
    return { frames, timedOut: false }
  } catch (error) {
    if (error === timeoutError || (controller.signal.aborted && error?.name === "AbortError")) {
      return { frames, timedOut: true }
    }
    throw error
  } finally {
    clearTimeout(timer)
    controller.abort()
  }
}
