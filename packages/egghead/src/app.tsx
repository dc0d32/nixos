// Ink driver. Walks the STEPS array, accumulates Answers, renders a
// final summary, and exits with the chosen Answers + proceed flag via
// the onDone callback. Each render shows a small banner, prior
// answers as a breadcrumb, and the current prompt.
import React, { useEffect, useState } from "react";
import { Box, Text, useApp, useInput } from "ink";
import TextInput from "ink-text-input";
import SelectInput from "ink-select-input";
import { Answers, STEPS, normalizeAnswers, StepDef } from "./steps.js";
import { listDisks } from "./lsblk.js";

const BANNER =
  "egghead — opinionated NixOS installer wizard (TUI, Ctrl-C to abort)";

interface AppProps {
  onDone: (result: { answers: Answers; proceed: boolean }) => void;
}

type Phase = "step" | "summary";

export const App: React.FC<AppProps> = ({ onDone }) => {
  const { exit } = useApp();
  const [answers, setAnswers] = useState<Partial<Answers>>({});
  const [stepIdx, setStepIdx] = useState(0);
  const [phase, setPhase] = useState<Phase>("step");
  const [error, setError] = useState<string | undefined>();

  // Skip steps whose shouldRun() returns false given prior answers.
  // We advance lazily inside the render path; here we just compute the
  // active step index based on `stepIdx` and what's been answered.
  const activeStep: StepDef | undefined = STEPS[stepIdx];

  // If activeStep is gated out, auto-skip without rendering.
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
  };

  // Ctrl-C aborts cleanly with exit code 1.
  useInput((input, key) => {
    if (key.escape || (key.ctrl && input === "c")) {
      exit();
      onDone({ answers: answers as Answers, proceed: false });
    }
  });

  if (phase === "summary") {
    return (
      <SummaryScreen
        answers={answers as Answers}
        onConfirm={(proceed) => {
          exit();
          onDone({ answers: answers as Answers, proceed });
        }}
      />
    );
  }

  if (!activeStep) return null;

  return (
    <Box flexDirection="column">
      <Header />
      <Breadcrumb answers={answers} />
      <Box marginTop={1} flexDirection="column">
        <Text>
          <Text color="cyan" bold>
            {activeStep.prompt}
          </Text>
          {activeStep.help ? (
            <Text color="gray">  ({activeStep.help})</Text>
          ) : null}
        </Text>
        <StepInput step={activeStep} answers={answers} onSubmit={submit} />
        {error ? <Text color="red">  ✘ {error}</Text> : null}
      </Box>
    </Box>
  );
};

const Header: React.FC = () => (
  <Box marginBottom={1}>
    <Text color="green" bold>{BANNER}</Text>
  </Box>
);

const Breadcrumb: React.FC<{ answers: Partial<Answers> }> = ({ answers }) => {
  const entries = Object.entries(answers);
  if (entries.length === 0) return null;
  return (
    <Box flexDirection="column">
      {entries.map(([k, v]) => (
        <Text key={k} color="gray">
          ✓ {k} = {v === "" ? "(empty)" : v}
        </Text>
      ))}
    </Box>
  );
};

interface StepInputProps {
  step: StepDef;
  answers: Partial<Answers>;
  onSubmit: (value: string) => void;
}

const StepInput: React.FC<StepInputProps> = ({ step, answers, onSubmit }) => {
  const defaultValue = step.defaultFrom(answers);

  if (step.kind === "text") {
    if (step.key === "DISK") {
      return <DiskInput defaultValue={defaultValue} onSubmit={onSubmit} />;
    }
    return <TextStep defaultValue={defaultValue} onSubmit={onSubmit} />;
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
  return (
    <Box flexDirection="column">
      <Header />
      <Text color="cyan" bold>═══ Summary ═══</Text>
      {Object.entries(answers).map(([k, v]) => (
        <Text key={k}>
          {"  "}
          <Text color="gray">{k.padEnd(18)}</Text>
          {": "}
          <Text>{v === "" ? "(empty)" : v}</Text>
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
