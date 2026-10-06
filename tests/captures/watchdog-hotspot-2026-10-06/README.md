# Watchdog connection captures, 6 Oct 2026

These files own the recorded inputs replayed by the `test_hotspot_*` and `test_the_same_latency_*` cases in `../../fm-memory-watchdog.test.sh`.
They were recorded by `bin/fm-memory-watchdog.sh` on 6 Oct 2026 from 00:44 to 01:45 BST, on a Windows 11 machine running the watchdog in WSL2 with NAT networking, whose only internet link was a phone's Wi-Fi hotspot.
They are replay inputs: the test rebuilds the loop's view of each probe from them rather than re-measuring a connection.

## What happened

Between 01:03 and 01:43 the latency to `1.1.1.1` rose to 300-2000 ms against a normal of about 45 ms and fell back on its own, while WSL's own traffic averaged about 60 KB/s and dropped to nothing for minutes at a time.
The watchdog then judged the connection on latency alone, so it held its connection gate closed, reported repeated overloads, and paused a worker carrying about 40 KB/s.

## Files

`latency.tsv` holds the 541 entries of the watchdog's shared latency ring (`state/.net-latency`) from 00:44:58 to 01:44:55, unchanged: the epoch of the tick that harvested a probe, then its round trip in whole milliseconds, or `timeout` (19 entries) for a probe with no answer.
The probes ran one every six to seven seconds, a single ping with a two-second limit.
The ring had already trimmed the 101 entries before 00:56:08 when this capture was taken, so those come from a timestamped dump of the same ring taken at 01:57, which matched the live ring on all 556 entries both held.

`traffic.tsv` holds the 220 samples of `state/watchdog-history` from 00:44:15 to 01:44:48, cut to three fields: the sample epoch, then the upload and download rates in KB/s of WSL's `eth0` over the interval since the previous sample.
Every other field, including the names of the tasks running then, is left out.
Those rates come from the interface's byte counters, so the test integrates them back into a counter for each probe; the reconstruction holds each sample's rate across its interval.
