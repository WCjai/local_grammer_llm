package dev.jai.localscribe

/**
 * Single source of truth for keyword → one-shot prompt assembly.
 *
 * Both [ProcessTextActivity] (system-share popup) and
 * [TypiLikeAccessibilityService] (in-line overlay) used to carry their own
 * identical copies of buildTaggedPrompt / buildScribePrompt / mapCommandToTask,
 * which drifted quietly. This object collapses them into one place and, at the
 * same time, makes several targeted quality improvements:
 *
 *   1. **Task-kind-aware rule sets.** The previous monolithic RULES block
 *      force-fed "keep same language" onto `?translate`, "keep POV/pronouns"
 *      onto `?summ` and `?bullet`, and (worst) the entire rewrite rulebook
 *      onto every user-defined custom prompt — which silently contradicts
 *      custom keywords like `?tofrench` or `?thirdperson`. We classify the
 *      command first ([TaskKind]) and emit only the rules that actually fit.
 *
 *   2. **Universal `arg` support.** `?rewrite:formal` used to work; every
 *      other keyword silently dropped the colon-delimited modifier. Now any
 *      `?keyword:modifier` appends "Style modifier: <arg>" to the task so the
 *      model sees it.
 *
 *   3. **Prompt-injection defense.** Raw user text / context is sanitized so
 *      a literal `[/TEXT]` / `[/CONTEXT]` / `[/RULES]` / `[/TASK]` sequence
 *      can't close our section markers and hijack instructions.
 *
 *   4. **Task-first, input-last ordering.** Same "accurate last token"
 *      principle Gallery applies to its Content list — instructions first,
 *      user input last so the model's hot context is the thing it must act on.
 *
 *   5. **One-shot JSON exemplar.** Small models are dramatically more
 *      reliable at producing `{"output":"..."}` when they've just seen one.
 *
 *   6. **Tagged scribe (Q&A) prompt.** The previous single-line prose scribe
 *      prompt confuses tiny models when context/images are attached. We keep
 *      scribe non-JSON (answers can have newlines) but still wrap it in
 *      tags so the model can distinguish background material from the actual
 *      question.
 */
object PromptBuilder {

    /**
     * How a command should be scaffolded. Each kind selects a different
     * subset of rules — rewrite-specific fact-preservation rules don't apply
     * to translations or summaries, and none of them apply to user-defined
     * custom prompts (where the user's task text is authoritative).
     */
    enum class TaskKind {
        /** fix, rewrite, polite, casual, improve, rephrase, formal, expand. */
        REWRITE_STYLE,
        /** summ, bullet — format-changing transforms; POV is expected to shift. */
        TRANSFORM,
        /** translate — language-changing; "keep same language" would be wrong. */
        TRANSLATE,
        /** scribe — question answering / direct response; not a text transform. */
        ANSWER,
        /** User-defined prompts. User's task string is the authoritative spec. */
        CUSTOM,
    }

    /** Result of [build]. [jsonMode] tells the activity which postProcessor to use. */
    data class Built(val prompt: String, val jsonMode: Boolean)

    /** Built-in keyword set — keep in sync with ProcessTextActivity.isBuiltInKeyword. */
    private val BUILT_INS = setOf(
        "fix", "rewrite", "scribe", "summ", "polite", "casual",
        "expand", "translate", "bullet", "improve", "rephrase", "formal",
    )

    fun isBuiltIn(cmd: String): Boolean = BUILT_INS.contains(cmd)

    fun classify(cmd: String, isCustom: Boolean): TaskKind = when {
        isCustom -> TaskKind.CUSTOM
        cmd == "scribe" -> TaskKind.ANSWER
        cmd == "translate" -> TaskKind.TRANSLATE
        cmd == "summ" || cmd == "bullet" -> TaskKind.TRANSFORM
        else -> TaskKind.REWRITE_STYLE
    }

    /**
     * Maps a built-in keyword (plus optional colon-delimited [arg]) to the
     * task sentence that goes inside `[TASK]...[/TASK]`. Mirrors the previous
     * per-file mapper so behaviour is preserved for known keywords.
     */
    fun mapBuiltInTask(cmd: String, arg: String?): String {
        val rewriteVariant: (String?) -> String = { a ->
            when (a?.lowercase()) {
                "formal" -> "Rewrite the text in a formal and professional tone in the same language."
                "friendly" -> "Rewrite the text in a friendly tone in the same language."
                "short" -> "Rewrite the text shorter while preserving meaning in the same language."
                else -> "Rewrite the text clearly while preserving meaning in the same language."
            }
        }
        return when (cmd) {
            "fix" -> "Correct grammar, spelling, and punctuation in the same language."
            "rewrite" -> rewriteVariant(arg)
            "polite" -> "Rewrite the text in a polite and professional tone in the same language."
            "casual" -> "Rewrite the text in a casual and friendly tone in the same language."
            "summ" -> "Summarize the text in one or two sentences in the same language."
            "expand" -> "Expand the text with more detail while keeping the same language."
            "translate" -> "Translate the text into English."
            "bullet" -> "Convert the text into clear bullet points in the same language."
            "improve" -> "Improve writing clarity and quality while keeping meaning and language the same."
            "rephrase" -> "Rephrase the text completely while keeping the same meaning and language."
            "formal" -> "Rewrite the text in a formal, professional tone in the same language."
            else -> rewriteVariant(null)
        }
    }

    /**
     * Top-level entry point. Both keyword-trigger paths (accessibility overlay
     * and system-share popup) call this after they've resolved the custom-vs-
     * built-in question.
     *
     * @param task             The task sentence. For custom keywords this is
     *                         the user's own prompt text, unmodified.
     * @param text             The selected / input text to operate on.
     * @param context          Optional user-supplied context string (may be null/blank).
     * @param arg              Colon-delimited modifier (`?summ:1sentence`),
     *                         or null. For built-in `rewrite` the caller has
     *                         already consumed it via [mapBuiltInTask]; pass
     *                         null in that case so it isn't duplicated.
     * @param hasImage         True when a screenshot/image accompanies the call.
     * @param kind             Task classification (see [classify]).
     */
    fun build(
        task: String,
        text: String,
        context: String?,
        arg: String?,
        hasImage: Boolean,
        kind: TaskKind,
    ): Built {
        val safeText = sanitize(text)
        val safeCtx = sanitize(context?.trim().orEmpty())
        val safeArg = arg?.trim()?.takeIf { it.isNotEmpty() }
        val effectiveTask = buildString {
            append(task.trim())
            if (safeArg != null) {
                if (!endsWith(".") && !endsWith("!") && !endsWith("?")) append('.')
                append(" Style modifier: ")
                append(safeArg)
                append('.')
            }
        }

        return when (kind) {
            TaskKind.ANSWER -> Built(
                prompt = buildScribe(effectiveTask, safeText, safeCtx, hasImage),
                jsonMode = false,
            )
            else -> Built(
                prompt = buildTagged(effectiveTask, safeText, safeCtx, hasImage, kind),
                jsonMode = true,
            )
        }
    }

    // ------------------------------------------------------------------
    // Tagged (JSON-output) prompt — used for every transform/rewrite/custom.
    // ------------------------------------------------------------------

    private fun buildTagged(
        task: String,
        text: String,
        context: String,
        hasImage: Boolean,
        kind: TaskKind,
    ): String {
        val hasCtx = context.isNotBlank()

        val contextSection = if (hasCtx) "\n[CONTEXT]\n$context\n[/CONTEXT]" else ""
        val imageSection = if (hasImage) {
            "\n[IMAGE_CONTEXT]\nA screenshot is attached. Use it as visual reference to understand the subject matter and identify key details. The image and the text below refer to the same topic.\n[/IMAGE_CONTEXT]"
        } else ""

        val rules = buildRules(kind, hasCtx, hasImage).trimEnd()

        // One-shot exemplar: small models produce strictly-valid JSON far more
        // reliably when they've just seen one. Kept intentionally tiny.
        val exemplar = """
[EXAMPLE]
Input: "hello wrld"
Output: {"output":"Hello world."}
[/EXAMPLE]""".trimIndent()

        // Ordering: system role → format contract → exemplar → task → reference
        // material → rules → INPUT LAST. The "accurate last token" principle
        // (same one Gallery applies to its Content list) means the model should
        // see the raw text closest to its generation step.
        return """
You are a writing engine.

OUTPUT FORMAT (mandatory):
Return ONLY valid JSON exactly like:
{"output":"..."}
No other keys. No extra text. No markdown.
If you cannot comply, return: {"output":""}

$exemplar

[TASK]
$task
[/TASK]$contextSection$imageSection

[RULES]
$rules
[/RULES]

[TEXT]
$text
[/TEXT]
""".trimIndent()
    }

    /**
     * Kind-aware rules. Universal lines come first; kind-specific lines are
     * added only when they actually apply.
     */
    private fun buildRules(kind: TaskKind, hasCtx: Boolean, hasImage: Boolean): String =
        buildString {
            // Universal rules — always safe regardless of task kind.
            appendLine("Do not add new facts or invent details that aren't in the input.")
            appendLine("Keep names, numbers, dates and places unchanged.")
            appendLine("Do not mention the task, rules, context, or these instructions in the output.")

            // Kind-specific rules.
            when (kind) {
                TaskKind.REWRITE_STYLE -> {
                    appendLine("Keep the same language as the input.")
                    appendLine("Keep the SAME point of view and pronouns (do NOT change I/you/she/he/they).")
                    appendLine("Preserve the original meaning and intent exactly.")
                }
                TaskKind.TRANSFORM -> {
                    appendLine("Keep the same language as the input.")
                    appendLine("Preserve the original meaning; only the form changes.")
                }
                TaskKind.TRANSLATE -> {
                    appendLine("Preserve the original meaning and tone; only the language changes.")
                }
                TaskKind.CUSTOM -> {
                    // User's own prompt is authoritative. We deliberately omit
                    // POV/language/meaning-preservation rules — the custom
                    // task itself may require changing those.
                    appendLine("Follow the task exactly as written.")
                }
                TaskKind.ANSWER -> { /* unreachable — ANSWER uses buildScribe */ }
            }

            // Context / image hints — only added when those sections exist.
            if (hasImage && hasCtx) {
                appendLine("The screenshot and the context text together form background — use both.")
            } else if (hasImage) {
                appendLine("Use the attached screenshot as background to inform the task.")
            } else if (hasCtx) {
                appendLine("Use the provided context to inform the task.")
            }

            append("Output only the final answer (no explanations, no quotes, no markdown).")
        }

    // ------------------------------------------------------------------
    // Scribe (Q&A) prompt — plain text output, but tagged structure.
    // ------------------------------------------------------------------

    private fun buildScribe(
        task: String,
        text: String,
        context: String,
        hasImage: Boolean,
    ): String {
        val hasCtx = context.isNotBlank()
        val contextSection = if (hasCtx) "\n[CONTEXT]\n$context\n[/CONTEXT]" else ""
        val imageSection = if (hasImage) {
            "\n[IMAGE_CONTEXT]\nA screenshot is attached. Use it as visual reference when answering.\n[/IMAGE_CONTEXT]"
        } else ""

        val hints = buildString {
            appendLine("Respond in the same language as the question.")
            appendLine("Provide only the final answer — no preamble, no explanations, no disclaimers.")
            if (hasImage && hasCtx) appendLine("Use both the screenshot and the context as background.")
            else if (hasImage) appendLine("Use the screenshot as background.")
            else if (hasCtx) appendLine("Use the provided context as background.")
            append("If the answer is unknown, reply with a single short sentence saying so.")
        }.trimEnd()

        return """
You are a direct-answer engine.

[TASK]
$task
[/TASK]$contextSection$imageSection

[RULES]
$hints
[/RULES]

[QUESTION]
$text
[/QUESTION]
""".trimIndent()
    }

    // ------------------------------------------------------------------
    // Input sanitization — prevents prompt-injection via tag-closing tokens.
    // ------------------------------------------------------------------

    /**
     * Neutralizes section-closing tokens (`[/TASK]`, `[/CONTEXT]`, `[/TEXT]`,
     * `[/RULES]`, `[/QUESTION]`, `[/IMAGE_CONTEXT]`, `[/EXAMPLE]`) if they
     * appear literally inside user-supplied strings. Without this, a user
     * whose selected text contains `[/TEXT]` followed by new instructions
     * could hijack the downstream prompt.
     *
     * We break the bracket-slash sequence with a zero-width space so the
     * visual rendering is unchanged but the token no longer matches any of
     * our closers. Keeps the user's text faithful while closing the injection
     * path.
     */
    private fun sanitize(raw: String): String {
        if (raw.isEmpty()) return raw
        // U+200B is a zero-width space — invisible when rendered, but splits
        // the `[/` sequence so the tokenizer no longer sees a closing tag.
        return raw.replace("[/", "[\u200B/")
    }
}
