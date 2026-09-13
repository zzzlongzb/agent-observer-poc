using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgentObserver.Hud
{
    internal sealed class ObserverScan
    {
        [JsonPropertyName("record_type")]
        public string RecordType { get; set; } = string.Empty;

        [JsonPropertyName("observed_at_unix_ms")]
        public long ObservedAtUnixMs { get; set; }

        [JsonPropertyName("session_count")]
        public int SessionCount { get; set; }

        [JsonPropertyName("sessions")]
        public List<ObserverSession> Sessions { get; set; } = new List<ObserverSession>();
    }

    internal sealed class ObserverSession
    {
        [JsonPropertyName("agent_family")]
        public string AgentFamily { get; set; } = "Unknown";

        [JsonPropertyName("surface")]
        public string Surface { get; set; } = "Unknown";

        [JsonPropertyName("native_session_id")]
        public string NativeSessionId { get; set; } = string.Empty;

        [JsonPropertyName("session_display_name")]
        public string? SessionDisplayName { get; set; }

        [JsonPropertyName("cwd")]
        public string? Cwd { get; set; }

        [JsonPropertyName("attention_state")]
        public string AttentionState { get; set; } = "UNKNOWN";

        [JsonPropertyName("evidence_freshness")]
        public string EvidenceFreshness { get; set; } = "NONE";

        [JsonPropertyName("session_liveness")]
        public string SessionLiveness { get; set; } = "UNKNOWN";

        [JsonPropertyName("last_attention_evidence_unix_ms")]
        public long? LastAttentionEvidenceUnixMs { get; set; }

        [JsonPropertyName("last_source_activity_unix_ms")]
        public long LastSourceActivityUnixMs { get; set; }
    }

    internal static class ScanParser
    {
        private static readonly JsonSerializerOptions Options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        };

        public static bool TryParse(string line, out ObserverScan? scan, out string? error)
        {
            scan = null;
            error = null;
            if (string.IsNullOrWhiteSpace(line))
            {
                return false;
            }

            try
            {
                var parsed = JsonSerializer.Deserialize<ObserverScan>(line, Options);
                if (parsed == null || parsed.RecordType != "session_scan")
                {
                    return false;
                }

                parsed.Sessions = parsed.Sessions ?? new List<ObserverSession>();
                scan = parsed;
                return true;
            }
            catch (JsonException exception)
            {
                error = exception.Message;
                return false;
            }
        }
    }

    internal enum TrafficLight
    {
        Red,
        Yellow,
        Green
    }

    internal static class TrafficLights
    {
        public static TrafficLight? From(ObserverSession session)
        {
            if (string.Equals(session.SessionLiveness, "LOST", StringComparison.OrdinalIgnoreCase))
            {
                return TrafficLight.Red;
            }

            switch ((session.AttentionState ?? string.Empty).ToUpperInvariant())
            {
                case "WORKING":
                    return TrafficLight.Yellow;
                case "NEEDS_ME":
                case "INTERRUPTED":
                case "ERROR":
                    return TrafficLight.Red;
                case "RESULT_READY":
                    return TrafficLight.Green;
                default:
                    return null;
            }
        }
    }

    internal sealed class SessionItem
    {
        public string Identity { get; private set; } = string.Empty;
        public string NativeSessionId { get; private set; } = string.Empty;
        public string DisplayName { get; private set; } = string.Empty;
        public string AgentFamily { get; private set; } = "Unknown";
        public string Surface { get; private set; } = "Unknown";
        public string Workspace { get; private set; } = "Unknown workspace";
        public string FamilySurface { get; private set; } = "Unknown";
        public string? FullCwd { get; private set; }
        public TrafficLight Light { get; private set; }
        public bool IsStale { get; private set; }
        public string AttentionState { get; private set; } = "UNKNOWN";
        public string EvidenceFreshness { get; private set; } = "NONE";
        public long LastChangeUnixMs { get; private set; }

        public string MetaText
        {
            get { return Workspace + " \u00B7 " + FamilySurface; }
        }

        public string HomepageCopy
        {
            get { return DisplayName + " " + MetaText; }
        }

        public string DebugTooltip
        {
            get
            {
                var cwd = string.IsNullOrWhiteSpace(FullCwd) ? "cwd unavailable" : FullCwd;
                var text = cwd
                    + Environment.NewLine
                    + FamilySurface
                    + Environment.NewLine
                    + "session " + NativeSessionId
                    + Environment.NewLine
                    + AttentionState;
                if (IsStale)
                {
                    text += Environment.NewLine + "No recent evidence";
                }

                return text;
            }
        }

        public static SessionItem? TryFrom(ObserverSession session)
        {
            var light = TrafficLights.From(session);
            if (!light.HasValue)
            {
                return null;
            }

            var family = NormalizeWord(session.AgentFamily);
            var surface = NormalizeWord(session.Surface);
            return new SessionItem
            {
                Identity = SessionIdentity.From(session),
                NativeSessionId = session.NativeSessionId ?? string.Empty,
                DisplayName = SessionNames.For(session),
                AgentFamily = family,
                Surface = surface,
                Workspace = ShortWorkspace(session.Cwd),
                FamilySurface = family + " " + surface,
                FullCwd = session.Cwd,
                Light = light.Value,
                IsStale = string.Equals(session.EvidenceFreshness, "STALE", StringComparison.OrdinalIgnoreCase),
                AttentionState = string.IsNullOrWhiteSpace(session.AttentionState) ? "UNKNOWN" : session.AttentionState,
                EvidenceFreshness = string.IsNullOrWhiteSpace(session.EvidenceFreshness) ? "NONE" : session.EvidenceFreshness,
                LastChangeUnixMs = session.LastAttentionEvidenceUnixMs.GetValueOrDefault() > 0
                    ? session.LastAttentionEvidenceUnixMs.GetValueOrDefault()
                    : session.LastSourceActivityUnixMs
            };
        }

        private static string ShortWorkspace(string? cwd)
        {
            if (string.IsNullOrWhiteSpace(cwd))
            {
                return "Unknown workspace";
            }

            var trimmed = cwd.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (trimmed.Length == 2 && trimmed[1] == ':')
            {
                return trimmed + Path.DirectorySeparatorChar;
            }

            var name = Path.GetFileName(trimmed);
            return string.IsNullOrWhiteSpace(name) ? cwd : name;
        }

        private static string NormalizeWord(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return "Unknown";
            }

            var trimmed = value.Trim();
            if (trimmed.Equals("Unknown surface", StringComparison.OrdinalIgnoreCase))
            {
                return "Unknown";
            }

            var lower = trimmed.ToLowerInvariant();
            if (lower == "cli")
            {
                return "CLI";
            }

            return char.ToUpperInvariant(lower[0]) + lower.Substring(1);
        }
    }

    internal static class SessionNames
    {
        public static string For(ObserverSession session)
        {
            var nativeTitle = Sanitize(session.SessionDisplayName);
            if (!string.IsNullOrWhiteSpace(nativeTitle))
            {
                return nativeTitle;
            }

            return "Session " + ShortNativeId(session.NativeSessionId);
        }

        public static string? Sanitize(string? raw)
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                return null;
            }

            var parts = raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            var collapsed = string.Join(" ", parts);
            if (collapsed.Length == 0 || LooksLikePath(collapsed))
            {
                return null;
            }

            if (collapsed.Length > 80)
            {
                collapsed = collapsed.Substring(0, 80).TrimEnd();
            }

            return collapsed.Length == 0 ? null : collapsed;
        }

        public static string ShortNativeId(string? nativeSessionId)
        {
            if (string.IsNullOrWhiteSpace(nativeSessionId))
            {
                return "unknown";
            }

            var trimmed = nativeSessionId.Trim();
            return trimmed.Length <= 8 ? trimmed : trimmed.Substring(0, 8);
        }

        private static bool LooksLikePath(string value)
        {
            return value.IndexOf(":\\", StringComparison.Ordinal) >= 0
                || value.IndexOf(":/", StringComparison.Ordinal) >= 0
                || value.StartsWith("\\", StringComparison.Ordinal)
                || value.StartsWith("/", StringComparison.Ordinal);
        }
    }

    internal static class SessionIdentity
    {
        public static string From(ObserverSession session)
        {
            return (session.AgentFamily ?? string.Empty) + ":" + (session.NativeSessionId ?? string.Empty);
        }
    }

    internal sealed class SessionSelection
    {
        public SessionSelection(IReadOnlyList<SessionItem> visible)
        {
            Visible = visible ?? Array.Empty<SessionItem>();
        }

        public IReadOnlyList<SessionItem> Visible { get; }

        public static SessionSelection Create(IEnumerable<ObserverSession> sessions, int maximum)
        {
            return new SessionAdmissionStore().Apply(sessions, maximum);
        }
    }

    internal sealed class SessionAdmissionStore
    {
        private readonly Dictionary<string, SessionItem> _admitted =
            new Dictionary<string, SessionItem>(StringComparer.Ordinal);
        private readonly Dictionary<string, TrafficLight> _lights =
            new Dictionary<string, TrafficLight>(StringComparer.Ordinal);
        private readonly List<string> _order = new List<string>();

        public int AdmittedCount
        {
            get { return _admitted.Count; }
        }

        public IReadOnlyList<SessionItem> Visible { get; private set; } = Array.Empty<SessionItem>();

        public SessionSelection Apply(IEnumerable<ObserverSession> sessions, int maximum)
        {
            var next = new Dictionary<string, SessionItem>(StringComparer.Ordinal);
            if (sessions != null)
            {
                foreach (var session in sessions)
                {
                    if (session == null)
                    {
                        continue;
                    }

                    var identity = SessionIdentity.From(session);
                    var projected = SessionItem.TryFrom(session);
                    if (projected == null)
                    {
                        continue;
                    }

                    if (_admitted.ContainsKey(identity) || AllowsFirstAdmission(session))
                    {
                        next[identity] = projected;
                    }
                }
            }

            // Stable ordering: rows that stay in the same light keep their
            // relative order. Evidence timestamps, freshness, titles, and
            // tooltips never move a row. New admissions and rows whose light
            // changed append to the end of their target light group.
            var survivors = new List<string>();
            foreach (var identity in _order)
            {
                SessionItem? item;
                TrafficLight previous;
                if (next.TryGetValue(identity, out item)
                    && _lights.TryGetValue(identity, out previous)
                    && item.Light == previous)
                {
                    survivors.Add(identity);
                }
            }

            var kept = new HashSet<string>(survivors, StringComparer.Ordinal);
            var movers = new List<string>();
            foreach (var pair in next)
            {
                if (!kept.Contains(pair.Key))
                {
                    movers.Add(pair.Key);
                }
            }

            movers.Sort(StringComparer.Ordinal);

            var reds = new List<string>();
            var yellows = new List<string>();
            var greens = new List<string>();
            foreach (var identity in survivors)
            {
                BucketFor(next[identity].Light, reds, yellows, greens).Add(identity);
            }

            foreach (var identity in movers)
            {
                BucketFor(next[identity].Light, reds, yellows, greens).Add(identity);
            }

            _order.Clear();
            _order.AddRange(reds);
            _order.AddRange(yellows);
            _order.AddRange(greens);

            _lights.Clear();
            _admitted.Clear();
            foreach (var pair in next)
            {
                _lights[pair.Key] = pair.Value.Light;
                _admitted[pair.Key] = pair.Value;
            }

            var visible = new List<SessionItem>(Math.Min(maximum, _order.Count));
            for (var index = 0; index < _order.Count && visible.Count < maximum; index++)
            {
                visible.Add(next[_order[index]]);
            }

            Visible = visible;
            return new SessionSelection(visible);
        }

        public static bool AllowsFirstAdmission(ObserverSession session)
        {
            var freshness = (session.EvidenceFreshness ?? string.Empty).ToUpperInvariant();
            return freshness == "FRESH" || freshness == "AGING";
        }

        private static List<string> BucketFor(
            TrafficLight light,
            List<string> reds,
            List<string> yellows,
            List<string> greens)
        {
            switch (light)
            {
                case TrafficLight.Red:
                    return reds;
                case TrafficLight.Yellow:
                    return yellows;
                default:
                    return greens;
            }
        }
    }

    internal static class HudStatusPolicy
    {
        public static bool IsRedundantLive(ObserverSourceState current, bool observerUnavailable)
        {
            return current == ObserverSourceState.Live && !observerUnavailable;
        }
    }

    internal sealed class VisibleRenderModel
    {
        private VisibleRenderModel(bool observerUnavailable, IReadOnlyList<SessionItem> rows, string fingerprint)
        {
            ObserverUnavailable = observerUnavailable;
            Rows = rows;
            Fingerprint = fingerprint;
        }

        public bool ObserverUnavailable { get; }

        public IReadOnlyList<SessionItem> Rows { get; }

        public string Fingerprint { get; }

        public static VisibleRenderModel Create(IReadOnlyList<SessionItem>? rows, bool observerUnavailable)
        {
            IReadOnlyList<SessionItem> list = rows == null || rows.Count == 0
                ? (IReadOnlyList<SessionItem>)Array.Empty<SessionItem>()
                : rows.ToList();
            var builder = new StringBuilder();
            builder.Append(observerUnavailable ? "unavailable=1" : "unavailable=0");
            for (var index = 0; index < list.Count; index++)
            {
                builder.Append('\n');
                builder.Append(RowFingerprint(index, list[index]));
            }

            return new VisibleRenderModel(observerUnavailable, list, builder.ToString());
        }

        public static string RowFingerprint(int position, SessionItem item)
        {
            return position
                + "\t" + item.Identity
                + "\t" + item.Light
                + "\t" + item.DisplayName
                + "\t" + item.MetaText
                + "\t" + NormalizeTooltip(item.DebugTooltip);
        }

        private static string NormalizeTooltip(string? tooltip)
        {
            return (tooltip ?? string.Empty).Replace("\r\n", "\n").Replace('\r', '\n');
        }
    }
}
