using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace AgentObserver.Hud
{
    internal static class HudSelfTests
    {
        public static int Run()
        {
            var tests = new Action[]
            {
                ParsesObserverScanIncludingOptionalDisplayName,
                MapsResultReadyToGreen,
                MapsWorkingToYellow,
                MapsNeedsMeToRed,
                MapsErrorInterruptedAndLostToRed,
                StaleDoesNotChangeLightColor,
                StaleNeverAppearsInHomepageCopy,
                FreshWorkingIsAdmittedAsYellow,
                AdmittedWorkingRetainsYellowFromFreshThroughAgingToStale,
                AdmittedNeedsMeRetainsRedWhenStale,
                AdmittedResultReadyRetainsGreenWhenStale,
                HistoricalStaleIsNotAdmittedWhenHudStarts,
                UnknownAndIdleStayOffHomepage,
                AdmittedSessionIsRemovedOnUnknownOrIdle,
                AdmittedWorkingUpdatesToNeedsMeRed,
                SameCwdSessionsStayIndependent,
                RepeatedScanDoesNotDuplicateRows,
                SourceErrorDoesNotClearAdmission,
                MissingTitleUsesShortNativeId,
                NativeTitleWinsOverCwdAndShortId,
                PreservesUnicodeSessionTitle,
                PreservesPiAndGrokFamiliesWithNativeTitles,
                TextRowsLeaveRoomForCjkAndDescenders,
                RejectsMalformedJsonWithoutThrowing,
                ListUpdatesWhenSessionsAppearOrChange,
                SortsRedBeforeYellowBeforeGreen,
                RetainedRowsStillSortRedYellowGreen,
                MaxEightRowsStillAppliesWithRetention,
                AgingIsEligibleForFirstAdmission,
                RestartedStoreDoesNotRestorePreviousAdmission,
                ReplayFixtureKeepsYellowThroughStaleWithoutStaleCopy,
                UsesRecentOnlyObserverWatchByDefault,
                UnchangedVisibleModelHasStableFingerprint,
                FreshAndAgingShareFingerprintWhenCopyIsUnchanged,
                StaleTooltipChangesFingerprint,
                RecencyWithoutReorderDoesNotChangeFingerprint,
                TimestampChangeKeepsStableOrderAndFingerprint,
                UnavailableFlagChangesFingerprint,
                YellowRowsKeepOrderWhenTimestampsAlternate,
                RedRowsKeepOrderWhenTimestampsChange,
                GreenRowsKeepOrderWhenTimestampsChange,
                NewAdmissionAppendsToLightGroupEnd,
                YellowTurningRedMovesToRedGroupEnd,
                RedTurningGreenMovesToGreenGroupEnd,
                TitleAndWorkspaceUpdateInPlace,
                FreshAgingStaleKeepsLightAndOrder,
                RepeatedIdenticalScanCommitsOnceWithZeroRowChanges,
                RemovalKeepsSameColorRelativeOrder,
                SameCwdSessionsKeepIndependentStableOrder,
                SourceErrorKeepsVisibleOrder,
                MaxEightRowsKeepsPriorityAndStableOrder,
                DuplicateLiveStatusIsIgnored,
                UnchangedScanDoesNotReplaceControls,
                ColorChangeReusesRowControl,
                NewSessionKeepsExistingRowInstance,
                UnavailableRowIsInsertedWithoutReplacingSessions,
                ClientSizeOnlyDependsOnVisibleRows
            };

            try
            {
                foreach (var test in tests)
                {
                    test();
                }

                var realScanPath = Environment.GetEnvironmentVariable("AGENT_OBSERVER_HUD_SCAN_FIXTURE");
                if (!string.IsNullOrWhiteSpace(realScanPath))
                {
                    var line = File.ReadAllText(realScanPath).Trim();
                    Assert(ScanParser.TryParse(line, out var scan, out var error), "real scan: " + error);
                    Assert(scan != null, "real scan parsed");
                    Assert(scan!.Sessions.Count == scan.SessionCount, "real scan session count");
                    var selection = SessionSelection.Create(scan.Sessions, 8);
                    AssertNoForbiddenHomepageCopy(selection.Visible);
                }

                Console.WriteLine("HUD self-tests: " + tests.Length + "/" + tests.Length + " passed");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("HUD self-test failed: " + error.Message);
                return 1;
            }
        }

        private static void ParsesObserverScanIncludingOptionalDisplayName()
        {
            const string json = "{\"record_type\":\"session_scan\",\"observed_at_unix_ms\":1000,\"session_count\":1,\"sessions\":[{\"agent_family\":\"Codex\",\"surface\":\"Desktop\",\"native_session_id\":\"11111111-1111-4111-8111-111111111111\",\"session_display_name\":null,\"cwd\":\"D:\\\\work\",\"attention_state\":\"WORKING\",\"evidence_freshness\":\"FRESH\",\"session_liveness\":\"UNKNOWN\",\"last_attention_evidence_unix_ms\":900,\"last_source_activity_unix_ms\":999}]}";
            Assert(ScanParser.TryParse(json, out var scan, out _), "scan should parse");
            Assert(scan != null && scan.Sessions.Count == 1, "scan should contain one session");
            Assert(scan!.Sessions[0].SessionDisplayName == null, "missing display name stays null");
        }

        private static void PreservesUnicodeSessionTitle()
        {
            var session = Session("RESULT_READY", "FRESH", "LIVE_IDLE");
            session.SessionDisplayName = "完成CP013验收并激活CP014";
            var item = MustFrom(session);
            Assert(item.DisplayName == "完成CP013验收并激活CP014", "Unicode title stays unchanged");
        }

        private static void PreservesPiAndGrokFamiliesWithNativeTitles()
        {
            var pi = Session("WORKING", "FRESH", "UNKNOWN");
            pi.AgentFamily = "Pi";
            pi.Surface = "CLI";
            pi.NativeSessionId = "pi-native-1";
            pi.SessionDisplayName = "修复行情回放";
            var grok = Session("RESULT_READY", "FRESH", "UNKNOWN");
            grok.AgentFamily = "Grok";
            grok.Surface = "CLI";
            grok.NativeSessionId = "grok-native-1";
            grok.SessionDisplayName = "完成 Build 审核";

            var rows = SessionSelection.Create(new[] { pi, grok }, 8).Visible;

            Assert(rows.Count == 2, "Pi and Grok sessions both reach the HUD");
            Assert(rows.Any(item => item.FamilySurface == "Pi CLI" && item.DisplayName == "修复行情回放"), "Pi keeps its native Unicode title");
            Assert(rows.Any(item => item.FamilySurface == "Grok CLI" && item.DisplayName == "完成 Build 审核"), "Grok keeps its native Unicode title");
        }

        private static void TextRowsLeaveRoomForCjkAndDescenders()
        {
            using var nameFont = new Font("Segoe UI Semibold", 9F, FontStyle.Bold, GraphicsUnit.Point);
            using var metaFont = new Font("Segoe UI", 8.5F, FontStyle.Regular, GraphicsUnit.Point);
            var flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
            var nameHeight = TextRenderer.MeasureText("完成验收 gyqp", nameFont, Size.Empty, flags).Height;
            var metaHeight = TextRenderer.MeasureText("strategy_replica · Codex Desktop gyqp", metaFont, Size.Empty, flags).Height;

            Assert(SessionRowControl.NameLineHeight >= nameHeight + 4, "name row leaves glyph margin");
            Assert(SessionRowControl.MetaLineHeight >= metaHeight + 4, "metadata row leaves descender margin");
            Assert(
                SessionRowControl.RowHeight >= SessionRowControl.NameLineHeight + SessionRowControl.MetaLineHeight + 8,
                "session row leaves vertical breathing room");
        }

        private static void UsesRecentOnlyObserverWatchByDefault()
        {
            var arguments = ObserverProcessClient.DefaultWatchArguments();
            Assert(
                arguments.SequenceEqual(new[] { "watch", "--json", "--interval-secs", "1" }),
                "HUD should use the recent-only watch stream");
            Assert(!arguments.Contains("--all"), "HUD default must not scan all historical sessions");
        }

        private static void UnchangedVisibleModelHasStableFingerprint()
        {
            var store = new SessionAdmissionStore();
            var session = Named("stable-fp", "WORKING", "FRESH");
            session.SessionDisplayName = "Stable task";
            var first = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            var second = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            Assert(first.Fingerprint == second.Fingerprint, "identical visible rows share a fingerprint");
            Assert(first.Fingerprint.IndexOf("stable-fp", StringComparison.Ordinal) >= 0, "fingerprint includes identity");
            Assert(first.Fingerprint.StartsWith("unavailable=0", StringComparison.Ordinal), "fingerprint includes observer availability");
        }

        private static void FreshAndAgingShareFingerprintWhenCopyIsUnchanged()
        {
            var store = new SessionAdmissionStore();
            var session = Named("fresh-aging-fp", "WORKING", "FRESH");
            session.SessionDisplayName = "Long running task";
            var fresh = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            session.EvidenceFreshness = "AGING";
            var aging = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            Assert(fresh.Fingerprint == aging.Fingerprint, "FRESH and AGING with the same homepage copy share a fingerprint");
        }

        private static void StaleTooltipChangesFingerprint()
        {
            var store = new SessionAdmissionStore();
            var session = Named("stale-fp", "WORKING", "FRESH");
            session.SessionDisplayName = "Long running task";
            var fresh = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            session.EvidenceFreshness = "STALE";
            var stale = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            Assert(fresh.Fingerprint != stale.Fingerprint, "STALE tooltip is part of the visible model");
            Assert(stale.Fingerprint.IndexOf("No recent evidence", StringComparison.Ordinal) >= 0, "stale fingerprint includes the tooltip");
        }

        private static void RecencyWithoutReorderDoesNotChangeFingerprint()
        {
            var session = Named("stable-recency", "WORKING", "FRESH");
            session.SessionDisplayName = "Stable task";
            session.LastAttentionEvidenceUnixMs = 1000;
            var first = MustFrom(session);
            session.LastAttentionEvidenceUnixMs = 2000;
            var second = MustFrom(session);
            Assert(
                VisibleRenderModel.Create(new[] { first }, false).Fingerprint
                == VisibleRenderModel.Create(new[] { second }, false).Fingerprint,
                "recency outside the visible model does not change the fingerprint");
        }

        private static void TimestampChangeKeepsStableOrderAndFingerprint()
        {
            var older = Named("older", "WORKING", "FRESH");
            older.LastAttentionEvidenceUnixMs = 10;
            older.SessionDisplayName = "Older";
            var newer = Named("newer", "WORKING", "FRESH");
            newer.LastAttentionEvidenceUnixMs = 20;
            newer.SessionDisplayName = "Newer";
            var store = new SessionAdmissionStore();
            var first = VisibleRenderModel.Create(store.Apply(new[] { older, newer }, 8).Visible, false);
            Assert(string.Join(",", first.Rows.Select(item => item.NativeSessionId)) == "newer,older", "same-scan admission order is deterministic");
            older.LastAttentionEvidenceUnixMs = 30;
            var second = VisibleRenderModel.Create(store.Apply(new[] { older, newer }, 8).Visible, false);
            Assert(first.Fingerprint == second.Fingerprint, "evidence timestamp updates must not reorder or commit");
            Assert(second.Rows[0].NativeSessionId == "newer", "relative order survives a newer timestamp on the second row");
            Assert(second.Rows[1].NativeSessionId == "older", "the row with the newest timestamp does not jump");
        }

        private static void YellowRowsKeepOrderWhenTimestampsAlternate()
        {
            var store = new SessionAdmissionStore();
            var first = Named("yellow-a", "WORKING", "FRESH");
            first.LastAttentionEvidenceUnixMs = 100;
            var second = Named("yellow-b", "WORKING", "FRESH");
            second.LastAttentionEvidenceUnixMs = 200;
            var initial = store.Apply(new[] { first, second }, 8);
            Assert(OrderOf(initial.Visible) == "yellow-a,yellow-b", "initial yellow order is the admission order");
            for (var round = 0; round < 6; round++)
            {
                if (round % 2 == 0)
                {
                    first.LastAttentionEvidenceUnixMs = 1000 + round;
                    second.LastAttentionEvidenceUnixMs = 100;
                }
                else
                {
                    first.LastAttentionEvidenceUnixMs = 100;
                    second.LastAttentionEvidenceUnixMs = 1000 + round;
                }

                var selection = store.Apply(new[] { first, second }, 8);
                Assert(OrderOf(selection.Visible) == "yellow-a,yellow-b", "alternating yellow timestamps never swap rows (round " + round + ")");
            }
        }

        private static void RedRowsKeepOrderWhenTimestampsChange()
        {
            var store = new SessionAdmissionStore();
            var first = Named("red-a", "NEEDS_ME", "FRESH");
            first.LastAttentionEvidenceUnixMs = 10;
            var second = Named("red-b", "INTERRUPTED", "FRESH");
            second.LastAttentionEvidenceUnixMs = 20;
            var third = Named("red-c", "ERROR", "FRESH");
            third.LastAttentionEvidenceUnixMs = 30;
            Assert(OrderOf(store.Apply(new[] { first, second, third }, 8).Visible) == "red-a,red-b,red-c", "initial red order is the admission order");
            first.LastAttentionEvidenceUnixMs = 5000;
            third.LastAttentionEvidenceUnixMs = 9000;
            var selection = store.Apply(new[] { first, second, third }, 8);
            Assert(OrderOf(selection.Visible) == "red-a,red-b,red-c", "red rows keep order when timestamps change");
            Assert(selection.Visible.All(item => item.Light == TrafficLight.Red), "all rows stay red");
        }

        private static void GreenRowsKeepOrderWhenTimestampsChange()
        {
            var store = new SessionAdmissionStore();
            var first = Named("green-a", "RESULT_READY", "FRESH");
            first.LastAttentionEvidenceUnixMs = 10;
            var second = Named("green-b", "RESULT_READY", "FRESH");
            second.LastAttentionEvidenceUnixMs = 20;
            Assert(OrderOf(store.Apply(new[] { first, second }, 8).Visible) == "green-a,green-b", "initial green order is the admission order");
            first.LastAttentionEvidenceUnixMs = 7000;
            var selection = store.Apply(new[] { first, second }, 8);
            Assert(OrderOf(selection.Visible) == "green-a,green-b", "green rows keep order when timestamps change");
            Assert(selection.Visible.All(item => item.Light == TrafficLight.Green), "all rows stay green");
        }

        private static void NewAdmissionAppendsToLightGroupEnd()
        {
            var store = new SessionAdmissionStore();
            var firstYellow = Named("y-one", "WORKING", "FRESH");
            var secondYellow = Named("y-two", "WORKING", "FRESH");
            var green = Named("g-one", "RESULT_READY", "FRESH");
            var initial = store.Apply(new[] { firstYellow, secondYellow, green }, 8);
            Assert(OrderOf(initial.Visible) == "y-one,y-two,g-one", "initial order is yellows then greens");
            var thirdYellow = Named("y-three", "WORKING", "FRESH");
            thirdYellow.LastAttentionEvidenceUnixMs = 999999;
            var selection = store.Apply(new[] { firstYellow, secondYellow, green, thirdYellow }, 8);
            Assert(OrderOf(selection.Visible) == "y-one,y-two,y-three,g-one", "a new yellow appends to the yellow group end, ahead of greens");
        }

        private static void YellowTurningRedMovesToRedGroupEnd()
        {
            var store = new SessionAdmissionStore();
            var red = Named("r-one", "NEEDS_ME", "FRESH");
            var mover = Named("y-mover", "WORKING", "FRESH");
            var yellow = Named("y-stay", "WORKING", "FRESH");
            var green = Named("g-stay", "RESULT_READY", "FRESH");
            var initial = store.Apply(new[] { red, mover, yellow, green }, 8);
            Assert(OrderOf(initial.Visible) == "r-one,y-mover,y-stay,g-stay", "initial order groups red, yellow, green");
            mover.AttentionState = "NEEDS_ME";
            var selection = store.Apply(new[] { red, mover, yellow, green }, 8);
            Assert(OrderOf(selection.Visible) == "r-one,y-mover,y-stay,g-stay", "a yellow turning red moves to the red group end, ahead of yellows");
            Assert(selection.Visible[1].NativeSessionId == "y-mover", "the moved row is the last red");
            Assert(selection.Visible[1].Light == TrafficLight.Red, "the moved row is red");
            Assert(selection.Visible[2].NativeSessionId == "y-stay", "the remaining yellow does not move");
        }

        private static void RedTurningGreenMovesToGreenGroupEnd()
        {
            var store = new SessionAdmissionStore();
            var mover = Named("r-mover", "NEEDS_ME", "FRESH");
            var green = Named("g-stay", "RESULT_READY", "FRESH");
            var yellow = Named("y-stay", "WORKING", "FRESH");
            var initial = store.Apply(new[] { mover, green, yellow }, 8);
            Assert(OrderOf(initial.Visible) == "r-mover,y-stay,g-stay", "initial order groups red, yellow, green");
            mover.AttentionState = "RESULT_READY";
            mover.SessionLiveness = "DETACHED";
            var selection = store.Apply(new[] { mover, green, yellow }, 8);
            Assert(OrderOf(selection.Visible) == "y-stay,g-stay,r-mover", "a red turning green moves to the green group end");
            Assert(selection.Visible.Single(item => item.NativeSessionId == "r-mover").Light == TrafficLight.Green, "the moved row is green");
        }

        private static void TitleAndWorkspaceUpdateInPlace()
        {
            using var panel = new DoubleBufferedFlowLayoutPanel { Width = HudMetrics.WindowWidth, Height = 400 };
            var presenter = new SessionListPresenter(panel);
            var store = new SessionAdmissionStore();
            var first = Named("title-a", "WORKING", "FRESH");
            first.SessionDisplayName = "Original title";
            var second = Named("title-b", "WORKING", "FRESH");
            var initial = VisibleRenderModel.Create(store.Apply(new[] { first, second }, 8).Visible, false);
            presenter.Commit(initial);
            var firstRow = panel.Controls[0];
            first.SessionDisplayName = "Renamed task";
            first.Cwd = "D:\\elsewhere";
            first.LastAttentionEvidenceUnixMs = 424242;
            var updated = VisibleRenderModel.Create(store.Apply(new[] { first, second }, 8).Visible, false);
            Assert(initial.Fingerprint != updated.Fingerprint, "a copy change is a visible change");
            Assert(presenter.Commit(updated), "copy change commits");
            Assert(presenter.LastChange.Created == 0, "no row is created for a copy change");
            Assert(presenter.LastChange.Removed == 0, "no row is removed for a copy change");
            Assert(presenter.LastChange.Reordered == 0, "no row moves for a copy change");
            Assert(presenter.LastChange.Updated == 1, "only the renamed row updates in place");
            Assert(ReferenceEquals(firstRow, panel.Controls[0]), "the renamed row keeps its position");
            Assert(((SessionRowControl)firstRow).AccessibleName == "Renamed task", "the new title renders in place");
            Assert(OrderOf(updated.Rows) == "title-a,title-b", "copy changes never reorder");
        }

        private static void FreshAgingStaleKeepsLightAndOrder()
        {
            var store = new SessionAdmissionStore();
            var red = Named("fs-red", "NEEDS_ME", "FRESH");
            var yellow = Named("fs-yellow", "WORKING", "FRESH");
            var green = Named("fs-green", "RESULT_READY", "FRESH");
            var fresh = store.Apply(new[] { red, yellow, green }, 8);
            var freshSignature = Signature(fresh.Visible);
            Assert(freshSignature == "fs-red:Red,fs-yellow:Yellow,fs-green:Green", "fresh signature is grouped");
            red.EvidenceFreshness = "AGING";
            yellow.EvidenceFreshness = "AGING";
            green.EvidenceFreshness = "AGING";
            var aging = store.Apply(new[] { red, yellow, green }, 8);
            Assert(Signature(aging.Visible) == freshSignature, "AGING changes neither light nor order");
            red.EvidenceFreshness = "STALE";
            yellow.EvidenceFreshness = "STALE";
            green.EvidenceFreshness = "STALE";
            var stale = store.Apply(new[] { red, yellow, green }, 8);
            Assert(Signature(stale.Visible) == freshSignature, "STALE changes neither light nor order");
            Assert(stale.Visible.All(item => item.IsStale), "all rows are stale");
        }

        private static void RepeatedIdenticalScanCommitsOnceWithZeroRowChanges()
        {
            using var panel = new DoubleBufferedFlowLayoutPanel { Width = HudMetrics.WindowWidth, Height = 400 };
            var presenter = new SessionListPresenter(panel);
            var store = new SessionAdmissionStore();
            var session = Named("repeat-id", "WORKING", "FRESH");
            session.SessionDisplayName = "Repeated scan";
            var first = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            Assert(presenter.Commit(first), "first scan commits");
            Assert(presenter.LastChange.Created == 1, "first scan creates one row");
            Assert(presenter.LastChange.Updated == 0, "first scan updates nothing else");
            Assert(presenter.LastChange.Removed == 0, "first scan removes nothing");
            Assert(presenter.LastChange.Reordered == 0, "first scan reorders nothing");
            var row = panel.Controls[0];
            var second = VisibleRenderModel.Create(store.Apply(new[] { session }, 8).Visible, false);
            Assert(!presenter.Commit(second), "identical scan does not commit");
            Assert(presenter.CommitCount == 1, "identical scan performs zero control updates");
            Assert(panel.Controls.Count == 1, "identical scan keeps one row");
            Assert(ReferenceEquals(row, panel.Controls[0]), "identical scan keeps the same control");
        }

        private static void RemovalKeepsSameColorRelativeOrder()
        {
            var store = new SessionAdmissionStore();
            var first = Named("a-keep", "WORKING", "FRESH");
            var middle = Named("b-drop", "WORKING", "FRESH");
            var last = Named("c-keep", "WORKING", "FRESH");
            Assert(OrderOf(store.Apply(new[] { first, middle, last }, 8).Visible) == "a-keep,b-drop,c-keep", "three yellows admitted in order");
            var selection = store.Apply(new[] { first, last }, 8);
            Assert(OrderOf(selection.Visible) == "a-keep,c-keep", "removing the middle yellow keeps the relative order of the rest");
        }

        private static void SameCwdSessionsKeepIndependentStableOrder()
        {
            var store = new SessionAdmissionStore();
            var first = Named("aaaaaaaa-1111-1111-1111-111111111111", "WORKING", "FRESH");
            first.Cwd = "D:\\synthetic-workspace";
            var second = Named("bbbbbbbb-2222-2222-2222-222222222222", "RESULT_READY", "FRESH");
            second.Cwd = "D:\\synthetic-workspace";
            var initial = store.Apply(new[] { first, second }, 8);
            Assert(initial.Visible.Count == 2, "same cwd sessions are not merged");
            Assert(OrderOf(initial.Visible) == "aaaaaaaa-1111-1111-1111-111111111111,bbbbbbbb-2222-2222-2222-222222222222", "yellow sorts ahead of the same-cwd green");
            first.LastAttentionEvidenceUnixMs = 8000;
            second.LastAttentionEvidenceUnixMs = 9000;
            var repeated = store.Apply(new[] { first, second }, 8);
            Assert(OrderOf(repeated.Visible) == OrderOf(initial.Visible), "same-cwd sessions keep their order across timestamp updates");
            Assert(repeated.Visible.Select(item => item.Identity).Distinct().Count() == 2, "identities stay distinct");
        }

        private static void SourceErrorKeepsVisibleOrder()
        {
            var store = new SessionAdmissionStore();
            var red = Named("err-red", "NEEDS_ME", "FRESH");
            var yellow = Named("err-yellow", "WORKING", "FRESH");
            var green = Named("err-green", "RESULT_READY", "FRESH");
            var before = store.Apply(new[] { red, yellow, green }, 8);
            var snapshot = OrderOf(before.Visible);
            Assert(snapshot == "err-red,err-yellow,err-green", "pre-error order is grouped and stable");

            // A source error must not call Apply. The retained snapshot keeps
            // every row in place until a reliable scan arrives.
            Assert(OrderOf(store.Visible) == snapshot, "source error does not clear or reorder the visible list");
            Assert(store.AdmittedCount == 3, "source error does not change admission");
            var recovered = store.Apply(new[] { red, yellow, green }, 8);
            Assert(OrderOf(recovered.Visible) == snapshot, "the first scan after an error keeps the same order");
        }

        private static void MaxEightRowsKeepsPriorityAndStableOrder()
        {
            var store = new SessionAdmissionStore();
            var reds = new[] { Named("r-1", "NEEDS_ME", "FRESH"), Named("r-2", "NEEDS_ME", "FRESH") };
            var yellows = new[]
            {
                Named("y-1", "WORKING", "FRESH"),
                Named("y-2", "WORKING", "FRESH"),
                Named("y-3", "WORKING", "FRESH")
            };
            var greens = new[]
            {
                Named("g-1", "RESULT_READY", "FRESH"),
                Named("g-2", "RESULT_READY", "FRESH"),
                Named("g-3", "RESULT_READY", "FRESH")
            };
            var all = reds.Concat(yellows).Concat(greens).ToArray();
            var initial = store.Apply(all, 8);
            Assert(OrderOf(initial.Visible) == "r-1,r-2,y-1,y-2,y-3,g-1,g-2,g-3", "eight rows keep red-yellow-green priority");

            var extraYellow = Named("y-4", "WORKING", "FRESH");
            extraYellow.LastAttentionEvidenceUnixMs = 424242;
            all = all.Concat(new[] { extraYellow }).ToArray();
            var capped = store.Apply(all, 8);
            Assert(OrderOf(capped.Visible) == "r-1,r-2,y-1,y-2,y-3,y-4,g-1,g-2", "the new yellow joins the yellow group end and the last green leaves the homepage");
            Assert(store.AdmittedCount == 9, "admission still tracks every eligible session");

            reds[0].LastAttentionEvidenceUnixMs = 999999;
            yellows[2].LastAttentionEvidenceUnixMs = 888888;
            var afterTimestamps = store.Apply(all, 8);
            Assert(OrderOf(afterTimestamps.Visible) == OrderOf(capped.Visible), "timestamps never reorder a capped list");

            var withoutFirstRed = all.Where(session => session.NativeSessionId != "r-1").ToArray();
            var afterRemoval = store.Apply(withoutFirstRed, 8);
            Assert(OrderOf(afterRemoval.Visible) == "r-2,y-1,y-2,y-3,y-4,g-1,g-2,g-3", "removing a red lets the hidden green back without reordering");
        }

        private static string OrderOf(IReadOnlyList<SessionItem> rows)
        {
            return string.Join(",", rows.Select(item => item.NativeSessionId));
        }

        private static string Signature(IReadOnlyList<SessionItem> rows)
        {
            return string.Join(",", rows.Select(item => item.NativeSessionId + ":" + item.Light));
        }

        private static void UnavailableFlagChangesFingerprint()
        {
            var item = MustFrom(Named("banner-fp", "WORKING", "FRESH"));
            var live = VisibleRenderModel.Create(new[] { item }, false);
            var unavailable = VisibleRenderModel.Create(new[] { item }, true);
            Assert(live.Fingerprint != unavailable.Fingerprint, "observer unavailable is part of the fingerprint");
            Assert(unavailable.Fingerprint.StartsWith("unavailable=1", StringComparison.Ordinal), "unavailable fingerprint is explicit");
        }

        private static void DuplicateLiveStatusIsIgnored()
        {
            Assert(HudStatusPolicy.IsRedundantLive(ObserverSourceState.Live, false), "already live is ignored");
            Assert(!HudStatusPolicy.IsRedundantLive(ObserverSourceState.Starting, false), "starting to live is not ignored");
            Assert(!HudStatusPolicy.IsRedundantLive(ObserverSourceState.Error, true), "recovery from error is not ignored");
            Assert(!HudStatusPolicy.IsRedundantLive(ObserverSourceState.Offline, true), "recovery from offline is not ignored");
            Assert(!HudStatusPolicy.IsRedundantLive(ObserverSourceState.Live, true), "live with an unavailable banner still recovers");
        }

        private static void UnchangedScanDoesNotReplaceControls()
        {
            using var panel = new DoubleBufferedFlowLayoutPanel { Width = HudMetrics.WindowWidth, Height = 400 };
            var presenter = new SessionListPresenter(panel);
            var item = MustFrom(Named("keep-row", "WORKING", "FRESH"));
            var model = VisibleRenderModel.Create(new[] { item }, false);
            Assert(presenter.Commit(model), "first visible model commits");
            Assert(panel.Controls.Count == 1, "one session row");
            var row = panel.Controls[0];
            Assert(!presenter.Commit(model), "identical model skips UI");
            Assert(presenter.CommitCount == 1, "skip does not count as a render commit");
            Assert(panel.Controls.Count == 1, "skip does not add rows");
            Assert(ReferenceEquals(row, panel.Controls[0]), "skip keeps the same control instance");
        }

        private static void ColorChangeReusesRowControl()
        {
            using var panel = new DoubleBufferedFlowLayoutPanel { Width = HudMetrics.WindowWidth, Height = 400 };
            var presenter = new SessionListPresenter(panel);
            var session = Named("color-row", "WORKING", "FRESH");
            session.SessionDisplayName = "Color change";
            Assert(presenter.Commit(VisibleRenderModel.Create(new[] { MustFrom(session) }, false)), "yellow commits");
            var row = (SessionRowControl)panel.Controls[0];
            Assert(row.BoundLight == TrafficLight.Yellow, "starts yellow");
            session.AttentionState = "NEEDS_ME";
            Assert(presenter.Commit(VisibleRenderModel.Create(new[] { MustFrom(session) }, false)), "red commits");
            Assert(panel.Controls.Count == 1, "still one row");
            Assert(ReferenceEquals(row, panel.Controls[0]), "color change reuses the row");
            Assert(row.BoundLight == TrafficLight.Red, "glyph updates in place");
            Assert(presenter.CommitCount == 2, "color change is one additional commit");
        }

        private static void NewSessionKeepsExistingRowInstance()
        {
            using var panel = new DoubleBufferedFlowLayoutPanel { Width = HudMetrics.WindowWidth, Height = 400 };
            var presenter = new SessionListPresenter(panel);
            var yellowSession = Named("keep-yellow", "WORKING", "FRESH");
            yellowSession.LastAttentionEvidenceUnixMs = 10;
            var yellow = MustFrom(yellowSession);
            presenter.Commit(VisibleRenderModel.Create(new[] { yellow }, false));
            var existing = panel.Controls[0];
            var redSession = Named("new-red", "NEEDS_ME", "FRESH");
            redSession.LastAttentionEvidenceUnixMs = 20;
            var red = MustFrom(redSession);
            presenter.Commit(VisibleRenderModel.Create(new[] { red, yellow }, false));
            Assert(panel.Controls.Count == 2, "new session is inserted");
            Assert(ReferenceEquals(existing, panel.Controls[1]), "existing yellow keeps its instance after a red is inserted");
            Assert(((SessionRowControl)existing).SessionIdentity.EndsWith("keep-yellow", StringComparison.Ordinal), "existing identity is unchanged");
        }

        private static void UnavailableRowIsInsertedWithoutReplacingSessions()
        {
            using var panel = new DoubleBufferedFlowLayoutPanel { Width = HudMetrics.WindowWidth, Height = 400 };
            var presenter = new SessionListPresenter(panel);
            var item = MustFrom(Named("during-error", "WORKING", "FRESH"));
            presenter.Commit(VisibleRenderModel.Create(new[] { item }, false));
            var row = panel.Controls[0];
            Assert(presenter.Commit(VisibleRenderModel.Create(new[] { item }, true)), "unavailable banner commits");
            Assert(panel.Controls.Count == 2, "banner is inserted above sessions");
            Assert(panel.Controls[0] is ObserverUnavailableRow, "unavailable row is first");
            Assert(ReferenceEquals(row, panel.Controls[1]), "session row is not rebuilt");
            Assert(presenter.Commit(VisibleRenderModel.Create(new[] { item }, false)), "recovery removes the banner");
            Assert(panel.Controls.Count == 1, "banner is gone");
            Assert(ReferenceEquals(row, panel.Controls[0]), "recovery keeps the session row");
        }

        private static void ClientSizeOnlyDependsOnVisibleRows()
        {
            var four = HudLayout.ClientSizeFor(HudMetrics.HeaderHeight, 4, false);
            var again = HudLayout.ClientSizeFor(HudMetrics.HeaderHeight, 4, false);
            Assert(four == again, "unchanged row count keeps the same client size");
            var withBanner = HudLayout.ClientSizeFor(HudMetrics.HeaderHeight, 4, true);
            Assert(withBanner.Height == four.Height + ObserverUnavailableRow.RowHeight, "unavailable row grows the window once");
            Assert(four.Width == HudMetrics.WindowWidth, "width is unchanged");
        }

        private static void MapsResultReadyToGreen()
        {
            var item = MustFrom(Session("RESULT_READY", "FRESH", "DETACHED"));
            Assert(item.Light == TrafficLight.Green, "RESULT_READY maps to green");
        }

        private static void MapsWorkingToYellow()
        {
            var item = MustFrom(Session("WORKING", "FRESH", "LIVE_ACTIVE"));
            Assert(item.Light == TrafficLight.Yellow, "WORKING maps to yellow");
        }

        private static void MapsNeedsMeToRed()
        {
            var item = MustFrom(Session("NEEDS_ME", "FRESH", "LIVE_ACTIVE"));
            Assert(item.Light == TrafficLight.Red, "NEEDS_ME maps to red");
        }

        private static void MapsErrorInterruptedAndLostToRed()
        {
            Assert(MustFrom(Session("ERROR", "FRESH", "UNKNOWN")).Light == TrafficLight.Red, "ERROR maps to red");
            Assert(MustFrom(Session("INTERRUPTED", "FRESH", "UNKNOWN")).Light == TrafficLight.Red, "INTERRUPTED maps to red");
            Assert(MustFrom(Session("WORKING", "FRESH", "LOST")).Light == TrafficLight.Red, "LOST maps to red");
        }

        private static void StaleDoesNotChangeLightColor()
        {
            Assert(TrafficLights.From(Session("RESULT_READY", "STALE", "DETACHED")) == TrafficLight.Green, "STALE keeps green");
            Assert(TrafficLights.From(Session("WORKING", "STALE", "UNKNOWN")) == TrafficLight.Yellow, "STALE keeps yellow");
            Assert(TrafficLights.From(Session("NEEDS_ME", "STALE", "UNKNOWN")) == TrafficLight.Red, "STALE keeps red");
            Assert(TrafficLights.From(Session("INTERRUPTED", "STALE", "UNKNOWN")) == TrafficLight.Red, "STALE keeps interrupted red");
            Assert(TrafficLights.From(Session("ERROR", "STALE", "UNKNOWN")) == TrafficLight.Red, "STALE keeps error red");

            var store = new SessionAdmissionStore();
            var working = Named("working-stale-color", "WORKING", "FRESH");
            store.Apply(new[] { working }, 8);
            working.EvidenceFreshness = "STALE";
            var retained = store.Apply(new[] { working }, 8);
            Assert(retained.Visible.Count == 1, "admitted WORKING remains after STALE");
            Assert(retained.Visible[0].Light == TrafficLight.Yellow, "STALE does not change yellow");

            var ready = Named("ready-stale-color", "RESULT_READY", "FRESH");
            var needs = Named("needs-stale-color", "NEEDS_ME", "FRESH");
            store.Apply(new[] { working, ready, needs }, 8);
            ready.EvidenceFreshness = "STALE";
            needs.EvidenceFreshness = "STALE";
            var allStale = store.Apply(new[] { working, ready, needs }, 8);
            Assert(allStale.Visible.Single(item => item.NativeSessionId == "working-stale-color").Light == TrafficLight.Yellow, "retained WORKING stays yellow");
            Assert(allStale.Visible.Single(item => item.NativeSessionId == "ready-stale-color").Light == TrafficLight.Green, "retained RESULT_READY stays green");
            Assert(allStale.Visible.Single(item => item.NativeSessionId == "needs-stale-color").Light == TrafficLight.Red, "retained NEEDS_ME stays red");
        }

        private static void StaleNeverAppearsInHomepageCopy()
        {
            var item = MustFrom(Session("WORKING", "STALE", "UNKNOWN"));
            AssertNoForbiddenHomepageCopy(new[] { item });
            Assert(item.HomepageCopy.IndexOf("WORKING", StringComparison.OrdinalIgnoreCase) < 0, "projected copy has no WORKING");
            Assert(item.DebugTooltip.IndexOf("STALE", StringComparison.OrdinalIgnoreCase) < 0, "tooltip does not use STALE as copy");
            Assert(item.DebugTooltip.Contains("No recent evidence"), "stale tooltip explains aged evidence");
        }

        private static void FreshWorkingIsAdmittedAsYellow()
        {
            var store = new SessionAdmissionStore();
            var session = Named("fresh-working", "WORKING", "FRESH");
            session.SessionDisplayName = "Long running task";
            var selection = store.Apply(new[] { session }, 8);
            Assert(selection.Visible.Count == 1, "FRESH WORKING is admitted");
            Assert(selection.Visible[0].Light == TrafficLight.Yellow, "FRESH WORKING shows yellow");
            Assert(selection.Visible[0].DisplayName == "Long running task", "native title is the homepage name");
            AssertNoForbiddenHomepageCopy(selection.Visible);
        }

        private static void AdmittedWorkingRetainsYellowFromFreshThroughAgingToStale()
        {
            var store = new SessionAdmissionStore();
            var live = Named("retain-working", "WORKING", "FRESH");
            live.SessionDisplayName = "Long running task";
            var historical = Named("historical-stale", "WORKING", "STALE");
            historical.SessionDisplayName = "Old archived session";

            var fresh = store.Apply(new[] { live, historical }, 8);
            Assert(fresh.Visible.Count == 1, "only the FRESH session is admitted");
            Assert(fresh.Visible[0].Light == TrafficLight.Yellow, "fresh scan is yellow");
            Assert(fresh.Visible[0].NativeSessionId == "retain-working", "historical STALE stays out");
            AssertNoForbiddenHomepageCopy(fresh.Visible);

            live.EvidenceFreshness = "AGING";
            var aging = store.Apply(new[] { live, historical }, 8);
            Assert(aging.Visible.Count == 1, "AGING keeps the admitted row");
            Assert(aging.Visible[0].Light == TrafficLight.Yellow, "AGING WORKING stays yellow");
            AssertNoForbiddenHomepageCopy(aging.Visible);

            live.EvidenceFreshness = "STALE";
            var stale = store.Apply(new[] { live, historical }, 8);
            Assert(stale.Visible.Count == 1, "STALE keeps the admitted row");
            Assert(stale.Visible[0].Light == TrafficLight.Yellow, "STALE WORKING stays yellow");
            Assert(stale.Visible[0].NativeSessionId == "retain-working", "historical STALE is still not admitted");
            Assert(stale.Visible[0].DisplayName == "Long running task", "name is unchanged");
            AssertNoForbiddenHomepageCopy(stale.Visible);
            Assert(stale.Visible[0].DebugTooltip.Contains("No recent evidence"), "tooltip may mention aged evidence");
        }

        private static void AdmittedNeedsMeRetainsRedWhenStale()
        {
            var store = new SessionAdmissionStore();
            var session = Named("retain-needs", "NEEDS_ME", "FRESH");
            store.Apply(new[] { session }, 8);
            session.EvidenceFreshness = "STALE";
            var retained = store.Apply(new[] { session }, 8);
            Assert(retained.Visible.Count == 1, "admitted NEEDS_ME remains");
            Assert(retained.Visible[0].Light == TrafficLight.Red, "NEEDS_ME + STALE stays red");
            AssertNoForbiddenHomepageCopy(retained.Visible);
        }

        private static void AdmittedResultReadyRetainsGreenWhenStale()
        {
            var store = new SessionAdmissionStore();
            var session = Named("retain-ready", "RESULT_READY", "FRESH");
            store.Apply(new[] { session }, 8);
            session.EvidenceFreshness = "AGING";
            store.Apply(new[] { session }, 8);
            session.EvidenceFreshness = "STALE";
            var retained = store.Apply(new[] { session }, 8);
            Assert(retained.Visible.Count == 1, "admitted RESULT_READY remains");
            Assert(retained.Visible[0].Light == TrafficLight.Green, "RESULT_READY + STALE stays green");
            AssertNoForbiddenHomepageCopy(retained.Visible);
        }

        private static void HistoricalStaleIsNotAdmittedWhenHudStarts()
        {
            var sessions = new List<ObserverSession>
            {
                Named("aa111111-working", "WORKING", "STALE"),
                Named("bb222222-needs", "NEEDS_ME", "STALE"),
                Named("cc333333-ready", "RESULT_READY", "FRESH")
            };
            var selection = SessionSelection.Create(sessions, 8);
            Assert(selection.Visible.Count == 1, "historical STALE rows are not first-admitted");
            Assert(selection.Visible[0].Light == TrafficLight.Green, "only the fresh completed row remains");
            Assert(selection.Visible[0].NativeSessionId == "cc333333-ready", "fresh session is the visible row");
            AssertNoForbiddenHomepageCopy(selection.Visible);
        }

        private static void UnknownAndIdleStayOffHomepage()
        {
            Assert(TrafficLights.From(Session("UNKNOWN", "FRESH", "UNKNOWN")) == null, "UNKNOWN has no light");
            Assert(TrafficLights.From(Session("IDLE", "FRESH", "LIVE_IDLE")) == null, "IDLE has no light");
            Assert(TrafficLights.From(Session("UNKNOWN", "FRESH", "LIVE_IDLE")) == null, "UNKNOWN+LIVE_IDLE has no light");
            var store = new SessionAdmissionStore();
            var selection = store.Apply(
                new[]
                {
                    Named("unknown-fresh", "UNKNOWN", "FRESH"),
                    Named("idle-fresh", "IDLE", "FRESH"),
                    Named("working-fresh", "WORKING", "FRESH")
                },
                8);
            Assert(selection.Visible.Count == 1, "UNKNOWN/IDLE stay off the homepage");
            Assert(selection.Visible[0].Light == TrafficLight.Yellow, "only WORKING remains");
            Assert(selection.Visible[0].NativeSessionId == "working-fresh", "WORKING is the admitted row");
        }

        private static void AdmittedSessionIsRemovedOnUnknownOrIdle()
        {
            var store = new SessionAdmissionStore();
            var session = Named("remove-me", "WORKING", "FRESH");
            Assert(store.Apply(new[] { session }, 8).Visible.Count == 1, "session is admitted");

            session.AttentionState = "UNKNOWN";
            session.EvidenceFreshness = "FRESH";
            var unknown = store.Apply(new[] { session }, 8);
            Assert(unknown.Visible.Count == 0, "explicit UNKNOWN removes an admitted session");
            Assert(store.AdmittedCount == 0, "UNKNOWN also leaves the admission set");

            session.AttentionState = "WORKING";
            session.EvidenceFreshness = "FRESH";
            Assert(store.Apply(new[] { session }, 8).Visible.Count == 1, "session can be admitted again");
            session.AttentionState = "IDLE";
            var idle = store.Apply(new[] { session }, 8);
            Assert(idle.Visible.Count == 0, "explicit IDLE removes an admitted session");
        }

        private static void AdmittedWorkingUpdatesToNeedsMeRed()
        {
            var store = new SessionAdmissionStore();
            var session = Named("color-change", "WORKING", "FRESH");
            var first = store.Apply(new[] { session }, 8);
            Assert(first.Visible[0].Light == TrafficLight.Yellow, "starts yellow");

            session.AttentionState = "NEEDS_ME";
            session.LastAttentionEvidenceUnixMs = 2000;
            var updated = store.Apply(new[] { session }, 8);
            Assert(updated.Visible.Count == 1, "same session stays a single row");
            Assert(updated.Visible[0].Light == TrafficLight.Red, "WORKING to NEEDS_ME updates yellow to red");
            Assert(updated.Visible[0].NativeSessionId == "color-change", "identity is unchanged");
        }

        private static void SameCwdSessionsStayIndependent()
        {
            var first = Named("aaaaaaaa-1111-1111-1111-111111111111", "WORKING", "FRESH");
            first.Cwd = "D:\\synthetic-workspace";
            var second = Named("bbbbbbbb-2222-2222-2222-222222222222", "RESULT_READY", "FRESH");
            second.Cwd = "D:\\synthetic-workspace";
            var store = new SessionAdmissionStore();
            var selection = store.Apply(new[] { first, second }, 8);
            Assert(selection.Visible.Count == 2, "same cwd sessions stay independent");
            Assert(selection.Visible.Select(item => item.Identity).Distinct().Count() == 2, "identities remain distinct");
            Assert(selection.Visible.All(item => item.Workspace == "synthetic-workspace"), "workspace is shared");
            Assert(selection.Visible.All(item => item.DisplayName.StartsWith("Session ", StringComparison.Ordinal)), "names do not collapse to cwd");

            first.EvidenceFreshness = "STALE";
            var retained = store.Apply(new[] { first, second }, 8);
            Assert(retained.Visible.Count == 2, "same-cwd sessions remain separate after one goes STALE");
            Assert(retained.Visible.Single(item => item.NativeSessionId.StartsWith("aaaaaaaa", StringComparison.Ordinal)).Light == TrafficLight.Yellow, "first identity keeps yellow");
            Assert(retained.Visible.Single(item => item.NativeSessionId.StartsWith("bbbbbbbb", StringComparison.Ordinal)).Light == TrafficLight.Green, "second identity keeps green");
        }

        private static void RepeatedScanDoesNotDuplicateRows()
        {
            var store = new SessionAdmissionStore();
            var session = Named("once-only", "WORKING", "FRESH");
            var duplicate = Named("once-only", "WORKING", "FRESH");
            var first = store.Apply(new[] { session, duplicate }, 8);
            Assert(first.Visible.Count == 1, "one scan with a repeated identity is a single row");
            var second = store.Apply(new[] { session }, 8);
            Assert(second.Visible.Count == 1, "a later scan of the same session is still one row");
            Assert(store.AdmittedCount == 1, "admission set does not accumulate duplicates");
        }

        private static void SourceErrorDoesNotClearAdmission()
        {
            var store = new SessionAdmissionStore();
            var live = Named("keep-on-error", "WORKING", "FRESH");
            var ready = Named("keep-green", "RESULT_READY", "FRESH");
            store.Apply(new[] { live, ready }, 8);
            live.EvidenceFreshness = "STALE";
            store.Apply(new[] { live, ready }, 8);
            var admitted = store.AdmittedCount;
            var snapshot = store.Visible.ToList();

            // A source error must not call Apply, including Apply(empty).
            Assert(admitted == 2, "two sessions stay admitted");
            Assert(snapshot.Count == 2, "last reliable list remains");
            Assert(snapshot.Any(item => item.Light == TrafficLight.Yellow && item.IsStale), "yellow STALE row remains during source error");
            Assert(snapshot.Any(item => item.Light == TrafficLight.Green), "green row remains during source error");
            AssertNoForbiddenHomepageCopy(snapshot);
            Assert(store.AdmittedCount == admitted, "admission set is unchanged when no scan arrives");
            Assert(store.Visible.Count == snapshot.Count, "visible list is unchanged when no scan arrives");
        }

        private static void MissingTitleUsesShortNativeId()
        {
            var session = Session("WORKING", "FRESH", "LIVE_ACTIVE");
            session.NativeSessionId = "11111111-1111-4111-8111-111111111111";
            session.Cwd = "D:\\synthetic-workspace";
            session.SessionDisplayName = null;
            var item = MustFrom(session);
            Assert(item.DisplayName == "Session 11111111", "fallback uses the first eight native id characters");
            Assert(item.Workspace == "synthetic-workspace", "cwd is the workspace line, not the title");
            Assert(item.DisplayName != item.Workspace, "cwd must not masquerade as the session name");
        }

        private static void NativeTitleWinsOverCwdAndShortId()
        {
            var session = Session("WORKING", "FRESH", "LIVE_ACTIVE");
            session.NativeSessionId = "11111111-1111-4111-8111-111111111111";
            session.Cwd = "D:\\synthetic-workspace";
            session.SessionDisplayName = "  Fix quota reset jitter  ";
            var item = MustFrom(session);
            Assert(item.DisplayName == "Fix quota reset jitter", "native title is the homepage name");
            Assert(item.MetaText == "synthetic-workspace \u00B7 Claude CLI", "second line is workspace and surface");

            session.SessionDisplayName = "D:\\synthetic-workspace";
            var rejected = MustFrom(session);
            Assert(rejected.DisplayName == "Session 11111111", "path-like titles fall back to the short id");
        }

        private static void RejectsMalformedJsonWithoutThrowing()
        {
            Assert(!ScanParser.TryParse("{not-json", out _, out var error), "invalid JSON rejected");
            Assert(!string.IsNullOrWhiteSpace(error), "invalid JSON reports an error");
            Assert(!ScanParser.TryParse("{\"record_type\":\"nope\"}", out _, out _), "non-scan JSON rejected");
        }

        private static void ListUpdatesWhenSessionsAppearOrChange()
        {
            var working = Named("one", "WORKING", "FRESH");
            working.LastAttentionEvidenceUnixMs = 10;
            var store = new SessionAdmissionStore();
            var first = store.Apply(new[] { working }, 8);
            Assert(first.Visible.Count == 1, "first scan has the working session");
            Assert(first.Visible[0].Light == TrafficLight.Yellow, "first scan is yellow");

            var needsMe = Named("two", "NEEDS_ME", "FRESH");
            needsMe.LastAttentionEvidenceUnixMs = 20;
            working.AttentionState = "RESULT_READY";
            working.LastAttentionEvidenceUnixMs = 30;
            var second = store.Apply(new[] { working, needsMe }, 8);
            Assert(second.Visible.Count == 2, "new session appears");
            Assert(second.Visible[0].Light == TrafficLight.Red, "new red session is visible");
            Assert(second.Visible[1].Light == TrafficLight.Green, "previous session updates to green");
        }

        private static void SortsRedBeforeYellowBeforeGreen()
        {
            var green = Named("green", "RESULT_READY", "FRESH");
            green.LastAttentionEvidenceUnixMs = 300;
            var yellow = Named("yellow", "WORKING", "FRESH");
            yellow.LastAttentionEvidenceUnixMs = 200;
            var redOlder = Named("red-old", "NEEDS_ME", "FRESH");
            redOlder.LastAttentionEvidenceUnixMs = 50;
            var redNewer = Named("red-new", "INTERRUPTED", "FRESH");
            redNewer.LastAttentionEvidenceUnixMs = 80;
            var selection = SessionSelection.Create(new[] { green, yellow, redOlder, redNewer }, 8);
            Assert(string.Join(",", selection.Visible.Select(item => item.NativeSessionId)) == "red-new,red-old,yellow,green", "red, yellow, green with stable admission order inside a color");
        }

        private static void RetainedRowsStillSortRedYellowGreen()
        {
            var store = new SessionAdmissionStore();
            var green = Named("green-keep", "RESULT_READY", "FRESH");
            green.LastAttentionEvidenceUnixMs = 300;
            var yellow = Named("yellow-keep", "WORKING", "FRESH");
            yellow.LastAttentionEvidenceUnixMs = 200;
            var red = Named("red-keep", "NEEDS_ME", "FRESH");
            red.LastAttentionEvidenceUnixMs = 50;
            store.Apply(new[] { green, yellow, red }, 8);
            green.EvidenceFreshness = "STALE";
            yellow.EvidenceFreshness = "STALE";
            red.EvidenceFreshness = "STALE";
            var retained = store.Apply(new[] { green, yellow, red }, 8);
            Assert(string.Join(",", retained.Visible.Select(item => item.Light.ToString())) == "Red,Yellow,Green", "retained rows still sort red, yellow, green");
            AssertNoForbiddenHomepageCopy(retained.Visible);
        }

        private static void MaxEightRowsStillAppliesWithRetention()
        {
            var store = new SessionAdmissionStore();
            var sessions = new List<ObserverSession>();
            for (var index = 0; index < 9; index++)
            {
                var session = Named("sess-" + index, "WORKING", "FRESH");
                session.LastAttentionEvidenceUnixMs = 1000 + index;
                sessions.Add(session);
            }

            var first = store.Apply(sessions, 8);
            Assert(first.Visible.Count == 8, "homepage cap remains eight");
            Assert(store.AdmittedCount == 9, "admission tracks every eligible session");

            foreach (var session in sessions)
            {
                session.EvidenceFreshness = "STALE";
            }

            var retained = store.Apply(sessions, 8);
            Assert(retained.Visible.Count == 8, "cap still applies after STALE retention");
            Assert(retained.Visible.All(item => item.Light == TrafficLight.Yellow), "retained working rows stay yellow");
            AssertNoForbiddenHomepageCopy(retained.Visible);

            var red = Named("sess-red", "NEEDS_ME", "FRESH");
            red.LastAttentionEvidenceUnixMs = 5000;
            sessions.Add(red);
            var withRed = store.Apply(sessions, 8);
            Assert(withRed.Visible.Count == 8, "cap still applies when a new red arrives");
            Assert(withRed.Visible[0].Light == TrafficLight.Red, "new red sorts ahead of retained yellows");
            Assert(withRed.Visible[0].NativeSessionId == "sess-red", "the new red is visible");
            Assert(withRed.Visible.Count(item => item.Light == TrafficLight.Yellow) == 7, "seven yellows remain under the cap");
        }

        private static void AgingIsEligibleForFirstAdmission()
        {
            var store = new SessionAdmissionStore();
            var session = Named("aging-admit", "WORKING", "AGING");
            var selection = store.Apply(new[] { session }, 8);
            Assert(selection.Visible.Count == 1, "AGING WORKING is eligible for first admission");
            Assert(selection.Visible[0].Light == TrafficLight.Yellow, "AGING WORKING is yellow");
        }

        private static void RestartedStoreDoesNotRestorePreviousAdmission()
        {
            var session = Named("restart-id", "WORKING", "FRESH");
            var firstHud = new SessionAdmissionStore();
            Assert(firstHud.Apply(new[] { session }, 8).Visible.Count == 1, "first HUD admits the live session");
            session.EvidenceFreshness = "STALE";
            Assert(firstHud.Apply(new[] { session }, 8).Visible.Count == 1, "first HUD retains STALE");

            var restartedHud = new SessionAdmissionStore();
            var afterRestart = restartedHud.Apply(new[] { session }, 8);
            Assert(afterRestart.Visible.Count == 0, "a new HUD process does not restore a previously admitted STALE session");
            Assert(restartedHud.AdmittedCount == 0, "restarted admission set starts empty");
        }

        private static void ReplayFixtureKeepsYellowThroughStaleWithoutStaleCopy()
        {
            var path = FindReplayFixture();
            Assert(File.Exists(path), "replay fixture exists: " + path);
            var store = new SessionAdmissionStore();
            SessionSelection? last = null;
            foreach (var line in File.ReadAllLines(path))
            {
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                Assert(ScanParser.TryParse(line, out var scan, out var error), "replay line parses: " + error);
                last = store.Apply(scan!.Sessions, 8);
                Assert(last.Visible.Count == 1, "replay row remains visible");
                Assert(last.Visible[0].Light == TrafficLight.Yellow, "replay row stays yellow");
                Assert(last.Visible[0].DisplayName == "Long running task", "replay name is stable");
                AssertNoForbiddenHomepageCopy(last.Visible);
            }

            Assert(last != null, "replay fixture applied scans");
            Assert(last!.Visible[0].IsStale, "final replay scan is aged evidence");
            Assert(last.Visible[0].DebugTooltip.Contains("No recent evidence"), "final tooltip mentions aged evidence");
        }

        private static string FindReplayFixture()
        {
            var current = new DirectoryInfo(AppContext.BaseDirectory);
            for (var depth = 0; depth < 10 && current != null; depth++, current = current.Parent)
            {
                var candidate = Path.Combine(current.FullName, "hud", "fixtures", "working-fresh-aging-stale.jsonl");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }

            return Path.Combine("hud", "fixtures", "working-fresh-aging-stale.jsonl");
        }

        private static SessionItem MustFrom(ObserverSession session)
        {
            var item = SessionItem.TryFrom(session);
            Assert(item != null, "session should project to a homepage row");
            return item!;
        }

        private static ObserverSession Named(string nativeId, string attention, string freshness)
        {
            var session = Session(attention, freshness, attention == "RESULT_READY" ? "DETACHED" : "LIVE_ACTIVE");
            session.NativeSessionId = nativeId;
            return session;
        }

        private static ObserverSession Session(string attention, string freshness, string liveness)
        {
            return new ObserverSession
            {
                AgentFamily = "Claude",
                Surface = "CLI",
                NativeSessionId = Guid.NewGuid().ToString(),
                Cwd = "D:\\work",
                AttentionState = attention,
                EvidenceFreshness = freshness,
                SessionLiveness = liveness,
                LastAttentionEvidenceUnixMs = 1000,
                LastSourceActivityUnixMs = 1000
            };
        }

        private static void AssertNoForbiddenHomepageCopy(IEnumerable<SessionItem> items)
        {
            foreach (var item in items)
            {
                Assert(item.HomepageCopy.IndexOf("STALE", StringComparison.OrdinalIgnoreCase) < 0, "homepage copy has no STALE");
                Assert(item.DisplayName.IndexOf("STALE", StringComparison.OrdinalIgnoreCase) < 0, "session name has no STALE");
                Assert(item.MetaText.IndexOf("STALE", StringComparison.OrdinalIgnoreCase) < 0, "meta line has no STALE");
                Assert(item.HomepageCopy.IndexOf("UNKNOWN", StringComparison.OrdinalIgnoreCase) < 0, "homepage copy has no UNKNOWN");
                Assert(item.HomepageCopy.IndexOf("NEEDS_ME", StringComparison.OrdinalIgnoreCase) < 0, "homepage copy has no NEEDS_ME");
                Assert(item.MetaText.IndexOf("WORKING", StringComparison.OrdinalIgnoreCase) < 0, "meta line has no WORKING");
            }
        }

        private static void Assert(bool condition, string message)
        {
            if (!condition)
            {
                throw new InvalidOperationException(message);
            }
        }
    }
}
