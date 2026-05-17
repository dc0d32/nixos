// Ink driver. Walks the STEPS array, accumulates Answers, renders a
// wizard-style layout (banner / step sidebar / active prompt /
// keymap footer), and exits with the chosen Answers + proceed flag
// via the onDone callback. Esc rewinds one step (with gated steps
// skipped). Ctrl-C aborts.
import React, { useEffect, useState } from "react";
import { Box, Text, useApp, useInput } from "ink";
import TextInput from "ink-text-input";
import SelectInput from "ink-select-input";
import { Answers, STEPS, normalizeAnswers, StepDef, ExtraUser } from "./steps.js";
import { listDisks } from "./lsblk.js";
import { AVAILABLE_FEATURES } from "./features.js";

const BANNER =
  "egghead — opinionated NixOS installer wizard";

interface AppProps {
  onDone: (result: { answers: Answers; proceed: boolean }) => void;
}

type Phase = "step" | "summary";

// Walk backward (or forward) through STEPS, skipping gated-out
// entries given the current answers. Returns the first index in the
// requested direction whose shouldRun passes, or -1 / STEPS.length
// if there is none.
function findStep(
  from: number,
  dir: 1 | -1,
  answers: Partial<Answers>,
): number {
  let i = from;
  while (i >= 0 && i < STEPS.length) {
    const s = STEPS[i]!;
    if (!s.shouldRun || s.shouldRun(answers)) return i;
    i += dir;
  }
  return i;
}

export const App: React.FC<AppProps> = ({ onDone }) => {
  const { exit } = useApp();
  const [answers, setAnswers] = useState<Partial<Answers>>({});
  const [stepIdx, setStepIdx] = useState(0);
  const [phase, setPhase] = useState<Phase>("step");
  const [error, setError] = useState<string | undefined>();
  // Bumps every time we (re)mount StepInput. Going back to the same
  // step needs to remount so the inner useState(defaultValue) picks
  // up the previously-entered answer.
  const [mountTick, setMountTick] = useState(0);

  const activeStep: StepDef | undefined = STEPS[stepIdx];

  // If activeStep is gated out, auto-skip forward.
  useEffect(() => {
    if (phase !== "step") return;
    if (!activeStep) {
      setPhase("summary");
      return;
    }
    if (activeStep.shouldRun && !activeStep.shouldRun(answers)) {
      setStepIdx((i) => i + 1);
    }
  }, [phase, activeStep, answers]);

  const submit = (value: string) => {
    if (!activeStep) return;
    const v = value.trim();
    if (activeStep.validate) {
      const err = activeStep.validate(v, answers);
      if (err) {
        setError(err);
        return;
      }
    }
    setError(undefined);
    const next: Partial<Answers> = { ...answers, [activeStep.key]: v };
    setAnswers(normalizeAnswers(next));
    setStepIdx((i) => i + 1);
    setMountTick((t) => t + 1);
  };

  // Esc rewinds; Ctrl-C aborts. From the summary, Esc returns to the
  // last non-gated step.
  useInput((input, key) => {
    if (key.ctrl && input === "c") {
      exit();
      onDone({ answers: answers as Answers, proceed: false });
      return;
    }
    if (!key.escape) return;
    if (phase === "summary") {
      const prev = findStep(STEPS.length - 1, -1, answers);
      if (prev >= 0) {
        setPhase("step");
        setStepIdx(prev);
        setError(undefined);
        setMountTick((t) => t + 1);
      }
      return;
    }
    const prev = findStep(stepIdx - 1, -1, answers);
    if (prev >= 0) {
      setStepIdx(prev);
      setError(undefined);
      setMountTick((t) => t + 1);
    }
  });

  if (phase === "summary") {
    return (
      <Box flexDirection="column">
        <Header />
        <SummaryScreen
          answers={answers as Answers}
          onConfirm={(proceed) => {
            exit();
            onDone({ answers: answers as Answers, proceed });
          }}
        />
        <Footer hint="Esc: back · Enter: confirm · Ctrl-C: quit" />
      </Box>
    );
  }

  if (!activeStep) return null;

  return (
    <Box flexDirection="column">
      <Header />
      <Box flexDirection="row">
        <Sidebar activeIdx={stepIdx} answers={answers} />
        <Box flexDirection="column" flexGrow={1} paddingX={1}>
          <Text color="cyan" bold>
            {activeStep.prompt}
          </Text>
          {activeStep.help ? (
            <Text color="gray">{activeStep.help}</Text>
          ) : null}
          <Box marginTop={1}>
            <StepInput
              key={`${activeStep.key}:${mountTick}`}
              step={activeStep}
              answers={answers}
              onSubmit={submit}
            />
          </Box>
          {error ? <Text color="red">  ✘ {error}</Text> : null}
        </Box>
      </Box>
      <Footer hint="Esc: back · Enter: next · Ctrl-C: quit" />
    </Box>
  );
};

const Header: React.FC = () => (
  <Box marginBottom={1}>
    <Text color="green" bold>{BANNER}</Text>
  </Box>
);

const Footer: React.FC<{ hint: string }> = ({ hint }) => (
  <Box marginTop={1}>
    <Text color="gray">{hint}</Text>
  </Box>
);

function truncate(s: string, n: number): string {
  if (s === "") return "(empty)";
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

const Sidebar: React.FC<{
  activeIdx: number;
  answers: Partial<Answers>;
}> = ({ activeIdx, answers }) => {
  return (
    <Box
      flexDirection="column"
      width={36}
      borderStyle="round"
      borderColor="gray"
      paddingX={1}
    >
      <Text bold color="cyan">steps</Text>
      {STEPS.map((s, i) => {
        const gated = s.shouldRun ? !s.shouldRun(answers) : false;
        const val = (answers as Record<string, string | undefined>)[s.key];
        const answered = val !== undefined;
        if (gated && !answered) return null;
        const isActive = i === activeIdx;
        const prefix = isActive ? "▸" : answered ? "✓" : "·";
        const color = isActive ? "yellow" : answered ? "green" : "gray";
        let shown = "";
        if (answered) {
          if (s.secret) {
            shown = val ? ": (set)" : ": (unset)";
          } else if (s.kind === "extras") {
            const n = countExtras(val!);
            shown = `: ${n} configured`;
          } else {
            shown = `: ${truncate(val!, 18)}`;
          }
        }
        return (
          <Text key={s.key} color={color} bold={isActive}>
            {prefix} {s.key}
            {shown}
          </Text>
        );
      })}
    </Box>
  );
};

function countExtras(json: string): number {
  try {
    const v = JSON.parse(json);
    return Array.isArray(v) ? v.length : 0;
  } catch {
    return 0;
  }
}

interface StepInputProps {
  step: StepDef;
  answers: Partial<Answers>;
  onSubmit: (value: string) => void;
}

const StepInput: React.FC<StepInputProps> = ({ step, answers, onSubmit }) => {
  const prior = (answers as Record<string, string | undefined>)[step.key];
  const defaultValue = prior !== undefined ? prior : step.defaultFrom(answers);

  if (step.kind === "text") {
    if (step.key === "DISK") {
      return <DiskInput defaultValue={defaultValue} onSubmit={onSubmit} />;
    }
    return <TextStep defaultValue={defaultValue} onSubmit={onSubmit} />;
  }

  if (step.kind === "password") {
    return <PasswordStep defaultValue={defaultValue} onSubmit={onSubmit} />;
  }

  if (step.kind === "extras") {
    return <ExtrasStep defaultValue={defaultValue} onSubmit={onSubmit} />;
  }

  if (step.kind === "choice") {
    const items =
      step.choices?.map((c) => ({ label: c, value: c })) ?? [];
    const initialIndex = Math.max(
      0,
      items.findIndex((i) => i.value === defaultValue),
    );
    return (
      <SelectInput
        items={items}
        initialIndex={initialIndex}
        onSelect={(item) => onSubmit(String(item.value))}
      />
    );
  }

  if (step.kind === "multi") {
    return <MultiSelectStep step={step} defaultValue={defaultValue} onSubmit={onSubmit} />;
  }

  // yesno
  const items = [
    { label: "yes", value: "yes" },
    { label: "no", value: "no" },
  ];
  const initialIndex = defaultValue === "yes" ? 0 : 1;
  return (
    <SelectInput
      items={items}
      initialIndex={initialIndex}
      onSelect={(item) => onSubmit(String(item.value))}
    />
  );
};

// Multi-select with checkboxes. Default pre-checks anything in the
// step's defaultValue (space-separated). Arrow keys / j-k navigate,
// space toggles, enter confirms. Submits a space-separated string
// of the picked feature keys.
const MultiSelectStep: React.FC<{
  step: StepDef;
  defaultValue: string;
  onSubmit: (value: string) => void;
}> = ({ step, defaultValue, onSubmit }) => {
  const choices = step.choices ?? AVAILABLE_FEATURES.map((f) => f.key);
  const descriptionByKey = new Map(
    AVAILABLE_FEATURES.map((f) => [f.key, f.description]),
  );
  const defaultSet = new Set(defaultValue.split(/\s+/).filter(Boolean));

  const [selected, setSelected] = useState<Set<string>>(defaultSet);
  const [cursor, setCursor] = useState(0);

  useInput((input, key) => {
    if (key.upArrow || input === "k") {
      setCursor((c) => (c - 1 + choices.length) % choices.length);
    } else if (key.downArrow || input === "j") {
      setCursor((c) => (c + 1) % choices.length);
    } else if (input === " ") {
      const k = choices[cursor]!;
      setSelected((s) => {
        const next = new Set(s);
        if (next.has(k)) next.delete(k);
        else next.add(k);
        return next;
      });
    } else if (key.return) {
      onSubmit(choices.filter((c) => selected.has(c)).join(" "));
    }
  });

  return (
    <Box flexDirection="column">
      <Text color="gray">
        {"  "}↑/↓ or j/k to move · space to toggle · enter to confirm
      </Text>
      <Box flexDirection="column" marginTop={1}>
        {choices.map((c, i) => {
          const checked = selected.has(c);
          const isCursor = i === cursor;
          const desc = descriptionByKey.get(c);
          return (
            <Text key={c} color={isCursor ? "cyan" : undefined}>
              {isCursor ? "›" : " "} [{checked ? "x" : " "}] {c}
              {desc ? <Text color="gray">  — {desc}</Text> : null}
            </Text>
          );
        })}
      </Box>
    </Box>
  );
};

const TextStep: React.FC<{
  defaultValue: string;
  onSubmit: (value: string) => void;
}> = ({ defaultValue, onSubmit }) => {
  const [value, setValue] = useState(defaultValue);
  return (
    <Box>
      <Text color="yellow">› </Text>
      <TextInput value={value} onChange={setValue} onSubmit={onSubmit} />
    </Box>
  );
};

const PasswordStep: React.FC<{
  defaultValue: string;
  onSubmit: (value: string) => void;
}> = ({ defaultValue, onSubmit }) => {
  const [value, setValue] = useState(defaultValue);
  return (
    <Box flexDirection="column">
      <Text color="gray">
        {"  "}characters hidden. Enter submits. Empty = no login.
      </Text>
      <Box marginTop={1}>
        <Text color="yellow">› </Text>
        <TextInput
          value={value}
          onChange={setValue}
          onSubmit={onSubmit}
          mask="*"
        />
      </Box>
    </Box>
  );
};

// ExtrasStep: tiny multi-user sub-wizard. Cycles through
// login → fullname → profile → password for each extra user, then
// asks "add another?". Submits the accumulated array as a
// JSON-encoded string so the bash side can ingest it via jq.
type ExtrasPhase =
  | "list"
  | "login"
  | "fullname"
  | "profile"
  | "password";

const ExtrasStep: React.FC<{
  defaultValue: string;
  onSubmit: (value: string) => void;
}> = ({ defaultValue, onSubmit }) => {
  // Parse seed value (env-provided or previously-submitted JSON).
  // Tolerate garbage by falling back to []; bash side validates again.
  const initial = (() => {
    try {
      const parsed = JSON.parse(defaultValue);
      if (Array.isArray(parsed)) return parsed as ExtraUser[];
    } catch {
      /* ignore */
    }
    return [];
  })();
  const [users, setUsers] = useState<ExtraUser[]>(initial);
  const [phase, setPhase] = useState<ExtrasPhase>("list");
  const [draft, setDraft] = useState<Partial<ExtraUser>>({});
  const [error, setError] = useState<string | undefined>();

  const finish = (final: ExtraUser[]) => {
    onSubmit(JSON.stringify(final));
  };

  if (phase === "list") {
    return (
      <Box flexDirection="column">
        {users.length === 0 ? (
          <Text color="gray">{"  "}(no extra users yet)</Text>
        ) : (
          users.map((u, i) => (
            <Text key={`${u.login}-${i}`} color="green">
              {"  "}✓ {u.login} ({u.fullname}, hm={u.profile})
            </Text>
          ))
        )}
        <Box marginTop={1}>
          <SelectInput
            items={[
              { label: "add another user", value: "add" },
              { label: "done — continue wizard", value: "done" },
            ]}
            onSelect={(item) => {
              if (item.value === "add") {
                setDraft({});
                setError(undefined);
                setPhase("login");
              } else {
                finish(users);
              }
            }}
          />
        </Box>
      </Box>
    );
  }

  if (phase === "login") {
    return (
      <Box flexDirection="column">
        <Text color="cyan">new user · login</Text>
        <Text color="gray">{"  "}must match [a-z_][a-z0-9_-]*</Text>
        <Box marginTop={1}>
          <Text color="yellow">› </Text>
          <DraftTextInput
            initial=""
            onSubmit={(v) => {
              if (!/^[a-z_][a-z0-9_-]*$/.test(v)) {
                setError("bad linux username");
                return;
              }
              if (users.some((u) => u.login === v)) {
                setError("login already used");
                return;
              }
              setError(undefined);
              setDraft({ login: v });
              setPhase("fullname");
            }}
          />
        </Box>
        {error ? <Text color="red">{"  "}✘ {error}</Text> : null}
      </Box>
    );
  }

  if (phase === "fullname") {
    return (
      <Box flexDirection="column">
        <Text color="cyan">new user · full name</Text>
        <Box marginTop={1}>
          <Text color="yellow">› </Text>
          <DraftTextInput
            initial={draft.login ?? ""}
            onSubmit={(v) => {
              setDraft({ ...draft, fullname: v || (draft.login ?? "") });
              setPhase("profile");
            }}
          />
        </Box>
      </Box>
    );
  }

  if (phase === "profile") {
    return (
      <Box flexDirection="column">
        <Text color="cyan">new user · HM profile</Text>
        <SelectInput
          items={[
            { label: "kid     — locked-down browser kiosk", value: "kid" },
            { label: "base    — minimal HM, no desktop", value: "base" },
            { label: "dev     — full dev tooling", value: "dev" },
            { label: "desktop — full daily-driver desktop", value: "desktop" },
          ]}
          onSelect={(item) => {
            setDraft({ ...draft, profile: String(item.value) });
            setPhase("password");
          }}
        />
      </Box>
    );
  }

  // password
  return (
    <Box flexDirection="column">
      <Text color="cyan">new user · password</Text>
      <Text color="gray">
        {"  "}characters hidden. Empty = no login (set later via sudo passwd).
      </Text>
      <Box marginTop={1}>
        <Text color="yellow">› </Text>
        <DraftTextInput
          initial=""
          mask="*"
          onSubmit={(v) => {
            const u: ExtraUser = {
              login: draft.login!,
              fullname: draft.fullname!,
              profile: draft.profile!,
              password: v,
            };
            setUsers((prev) => [...prev, u]);
            setDraft({});
            setPhase("list");
          }}
        />
      </Box>
    </Box>
  );
};

// Tiny stateful TextInput wrapper used inside ExtrasStep. Plain
// TextStep is controlled by app.tsx's outer state; here each draft
// substep needs its own input state that resets between phases.
const DraftTextInput: React.FC<{
  initial: string;
  mask?: string;
  onSubmit: (value: string) => void;
}> = ({ initial, mask, onSubmit }) => {
  const [v, setV] = useState(initial);
  return (
    <TextInput value={v} onChange={setV} onSubmit={onSubmit} mask={mask} />
  );
};

const DiskInput: React.FC<{
  defaultValue: string;
  onSubmit: (value: string) => void;
}> = ({ defaultValue, onSubmit }) => {
  const [disks] = useState(() => listDisks());
  const [value, setValue] = useState(defaultValue);
  return (
    <Box flexDirection="column">
      {disks.length > 0 ? (
        <Box flexDirection="column" marginBottom={1}>
          <Text color="gray">  Disks visible on this system:</Text>
          {disks.map((d) => (
            <Text key={d.path} color="gray">
              {"    "}
              {d.path}  {d.size}  {d.model}
            </Text>
          ))}
        </Box>
      ) : null}
      <Box>
        <Text color="yellow">› </Text>
        <TextInput value={value} onChange={setValue} onSubmit={onSubmit} />
      </Box>
    </Box>
  );
};

const SummaryScreen: React.FC<{
  answers: Answers;
  onConfirm: (proceed: boolean) => void;
}> = ({ answers, onConfirm }) => {
  const secretKeys = new Set(
    STEPS.filter((s) => s.secret).map((s) => s.key as string),
  );
  const formatValue = (k: string, v: string): string => {
    if (secretKeys.has(k)) return v ? "(set)" : "(unset)";
    if (k === "EXTRA_USERS_JSON") {
      const n = countExtras(v);
      return n === 0 ? "(none)" : `${n} configured`;
    }
    return v === "" ? "(empty)" : v;
  };
  return (
    <Box flexDirection="column">
      <Text color="cyan" bold>═══ Summary ═══</Text>
      {Object.entries(answers).map(([k, v]) => (
        <Text key={k}>
          {"  "}
          <Text color="gray">{k.padEnd(18)}</Text>
          {": "}
          <Text>{formatValue(k, String(v))}</Text>
        </Text>
      ))}
      <Box marginTop={1}>
        <Text color="yellow">proceed to write files + commit?</Text>
      </Box>
      <SelectInput
        items={[
          { label: "yes — write the host bridge + commit + install", value: "yes" },
          { label: "no — abort, write nothing", value: "no" },
        ]}
        onSelect={(item) => onConfirm(item.value === "yes")}
      />
    </Box>
  );
};
