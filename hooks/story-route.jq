# Policy defaults stay explicit and pinned for Desktop. Provider-specific IDs
# can be configured separately from their capability family and context window.
def require($ok; $message): if $ok then . else error($message) end;
def positive: type == "number" and . > 0 and floor == .;
def nonnegative: type == "number" and . >= 0 and floor == .;
def text: type == "string" and test("\\S");
def model_rank: {haiku:0, sonnet:1, opus:2}[.];
def effort_rank: {low:0, medium:1, high:2, xhigh:3, max:4}[.];
{
  planning:{family:"opus",effort:"high"},
  implementation:{family:"sonnet",effort:"medium"},
  complex:{family:"opus",effort:"high"},
  review:{family:"sonnet",effort:"high"},
  requirements:{family:"sonnet",effort:"medium"},
  documentation:{family:"sonnet",effort:"medium"},
  retrieval:{family:"haiku",effort:"low"},
  verification:{family:"haiku",effort:"low"}
} as $defaults |
{plan:"planning",implement:"implementation","implement-track":"implementation",
 "pr-review":"review",reader:"retrieval",verification:"verification",
 "requirements-review":"requirements","architect-review":"review",
 "documentation-review":"documentation","requirements-verify":"review"} as $roles |
require($configs|length == 1; "config must contain one JSON object") |
$configs[0] as $cfg |
require($cfg|type == "object"; "config must be an object") |
require(($cfg|has("routing")|not) or ($cfg.routing|type == "object"); "routing must be an object") |
($cfg.routing // {}) as $routing |
require($routing|type == "object"; "routing must be an object") |
require(($routing|keys) - ["models","profiles","startupTokens","targetSessionTokens"] | length == 0; "unknown routing setting") |
require(($routing|has("profiles")|not) or ($routing.profiles|type == "object"); "routing.profiles must be an object") |
require(($routing|has("models")|not) or ($routing.models|type == "object"); "routing.models must be an object") |
($routing.profiles // {}) as $overrides |
require($overrides|type == "object"; "routing.profiles must be an object") |
require(($overrides|keys) - ($defaults|keys) | length == 0; "unknown routing profile") |
require(all($overrides[]; type == "object" and ((keys - ["family","effort"])|length == 0)); "profile overrides accept family and effort only") |
($defaults * $overrides) as $profiles |
require(all($profiles[]; (.family|model_rank) != null and (.effort|effort_rank) != null); "unsupported family or effort") |
({haiku:{id:"claude-haiku-5-5",window:1000000},sonnet:{id:"claude-sonnet-5-5",window:1000000},opus:{id:"claude-opus-5-5",window:1000000}} * ($routing.models // {})) as $models |
require(($models|keys) == ["haiku","opus","sonnet"]; "unknown model family") |
require(all($models[]; type == "object" and (.id|text) and (.window|positive) and ((keys - ["id","window"])|length == 0)); "models require a nonempty id and positive integer window") |
(if $routing|has("startupTokens") then $routing.startupTokens else 100000 end) as $startup |
(if $routing|has("targetSessionTokens") then $routing.targetSessionTokens else 200000 end) as $budget |
($cfg.checkpointPercent // 35) as $checkpoint |
($cfg.backstopTokens // 432000) as $backstop |
require(($startup|nonnegative) and ($budget|positive); "invalid startupTokens/targetSessionTokens") |
require(($checkpoint|type == "number") and $checkpoint > 0 and $checkpoint < 100 and ($backstop|positive); "invalid checkpoint/backstop") |
require($roles[$role] != null; "unknown handoff role") |
require($profile == "" or $profiles[$profile] != null; "unknown specialist profile") |
require($effort == "" or ($effort|effort_rank) != null; "unsupported specialist effort") |
(if $profile == "" then $roles[$role] else $profile end) as $selectedProfile |
require($manifest|type == "object" and (.tasks|type == "array"); "manifest requires a tasks array") |
require(all($manifest.tasks[];
  type == "object" and (.id|type == "string" and test("^[A-Za-z0-9._-]+$")) and
  $profiles[.profile] != null and (.inputTokens|nonnegative) and (.workTokens|positive) and (.reason|text));
  "each task requires id, known profile, nonnegative inputTokens, positive workTokens and reason") |
require(($manifest.tasks|map(.id)|unique|length) == ($manifest.tasks|length); "duplicate task id") |
(if $ids == "" then [] else $ids|gsub("#";"")|split(",") end) as $wanted |
require(($wanted|length) == ($wanted|unique|length) and all($wanted[]; test("^[A-Za-z0-9._-]+$")); "invalid or duplicate requested task ids") |
require(all($wanted[]; . as $id | any($manifest.tasks[]; .id == $id)); "requested task missing from routing manifest") |
[$manifest.tasks[] | select(.id as $id | $wanted|index($id))] as $tasks |
require(($role != "implement-track" and $role != "implement") or ($tasks|length > 0); "implementation routing requires task estimates") |
(if $role == "implement-track" then [$tasks[] | $profiles[.profile]]
 else [$profiles[$selectedProfile]] + [$tasks[] | $profiles[.profile]] end) as $choices |
($choices|max_by(.family|model_rank)|.family) as $family |
(if $effort != "" then $effort else $choices|max_by(.effort|effort_rank)|.effort end) as $selectedEffort |
($startup + ([$tasks[]|.inputTokens + .workTokens]|add // 0)) as $estimate |
([($models[$family].window * $checkpoint / 100|floor), ($backstop * 0.85|floor)]|min) as $compact |
([$budget, $compact]|min) as $target |
{role:$role, family:$family, model:$models[$family].id, effort:$selectedEffort,
 tasks:$wanted, estimatedContextTokens:$estimate, sessionTargetTokens:$target,
 sizing:(if $estimate >= $target then "consider-splitting" else "within-target" end),
 compactionLikely:($estimate >= $compact),
 warnings:(if $estimate >= $target then ["CONSIDER SPLITTING: estimated context \($estimate) reaches planning target \($target). Prefer additional independent handoffs when they reduce total time and tokens. Continue with checkpoint/compaction when dependencies or restart overhead make splitting worse."] else [] end),
 reason:(if $tasks|length > 0 then [$tasks[]|"#\(.id) \(.profile): \(.reason)"]|join("; ")
 elif $profile == "" and $effort == "" then "role default: \($roles[$role]); estimate includes startup only"
 else "profile: \($selectedProfile)\(if $effort != "" then "; effort override: \($effort)" else "" end); estimate includes startup only" end)}
