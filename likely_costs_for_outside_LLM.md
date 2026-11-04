# Likely costs for an outside (paid) LLM

What it would cost to send the cameras' classification calls to a paid vision LLM service instead of Ollama
(qwen3-vl:8b) on ada. Written 2026-11-02. Prices change often: check each vendor's own pricing page before deciding.

**Short answer:** about 915 calls a day for both cameras. With a cheap vision model that would cost roughly
**$0.04–0.15 per camera per day** (about $2–7 a month for both cameras). A mid-size model like Claude Sonnet runs about
$1–1.30 per camera per day. Today it runs free on ada's GPU, apart from electricity.

## Daily requests per camera

Measured from each camera's `local/<camera>/history.jsonl` (porch cam: 23 days, 2026-10-10 to 11-01; pet door: 9
days, 10-24 to 11-01) and, for the pet door's early checks, `~/logs/pet_watch.log` (10-28 to 11-01).

| | Porch cam | Pet door |
|---|---|---|
| Motion events | 591 | 132 |
| Calls on the saved movie (4 frames in one grid image) | 422 | 117 |
| Early single-frame checks (`google_home.early`) | none | ~255 |
| Extra "cute sentence" calls for Google Home (`google_home.cute`) | none | ~5 |
| **Total calls** | **~422** | **~377** |
| Input tokens per call | ~1,300 | ~1,850 per movie call, ~700 per early check |
| **Input tokens per day** | **~548,000** | **~395,000** |
| Output tokens per day (answer is a short JSON, ~50 tokens) | ~21,000 | ~19,000 |

- **Token counts** are qwen3-vl's (`prompt_tokens` in the history log). Each vendor counts image tokens differently, so a
  paid service could be up to about 2× higher or lower. The early-check figure (~700) is an estimate: one 640×480
  frame plus the question.
- **Porch false alarms:** most porch calls are motion with nothing there (wind, light, the green-box problem). Fixing
  those would cut its cost almost in proportion.

## Estimated cost per camera per day

| Vendor | Model | Price per 1M tokens (in / out) | Porch cam | Pet door | Both, per month |
|---|---|---|---|---|---|
| Amazon Bedrock | Nova Lite | $0.06 / $0.24 | $0.04 | $0.03 | ~$2 |
| Google | Gemini 2.5 Flash-Lite | $0.10 / $0.40 | $0.06 | $0.05 | ~$3 |
| Anthropic | Claude Haiku 5.5 | $0.10 / $0.50 | $0.07 | $0.05 | ~$3.50 |
| DeepInfra | Qwen3-VL-235B (bigger version of the model family we run) | $0.20 / $0.88 | $0.13 | $0.10 | ~$7 |
| OpenAI | GPT-5.4 nano | $0.20 / $1.25 | $0.14 | $0.10 | ~$7 |
| Alibaba Cloud | Qwen3-VL-Plus | $0.20 / $1.60 | $0.14 | $0.11 | ~$7.50 |
| Google | Gemini 3.1 Flash-Lite | $0.25 / $1.50 | $0.17 | $0.13 | ~$9 |
| Google | Gemini 3 Flash | $0.50 / $3.00 | $0.34 | $0.25 | ~$18 |
| OpenAI | GPT-5.4 mini | $0.75 / $4.50 | $0.51 | $0.38 | ~$27 |
| Anthropic | Claude Sonnet 5.5 | $2 / $10 | $1.31 | $0.98 | ~$69 |
| Anthropic | Claude Opus 5.5 | $4 / $20 | $2.61 | $1.96 | ~$137 |
| Amazon | Rekognition (labels only, priced per image) | $1 per 1,000 images | $0.42 | $0.37 | ~$24 |
| Google | Cloud Vision (labels only, priced per image) | $1.50 per 1,000 images | $0.63 | $0.56 | ~$36, less 1,000 free images a month |

Cost per day = input tokens × input price + output tokens × output price, using the daily totals above.

## Caveats

- **Prices aren't all verified.** The Claude prices come from Anthropic's model table (dated 2026-10-06). The other
  vendors' prices come from third-party price trackers, which disagree in places. OpenAI's and Gemini's current model
  lineups in particular weren't consistent across sources.
- **Thinking tokens.** Some newer models think before answering, and those tokens are billed as output. Claude Haiku
  5.5 thinks by default. For a short JSON answer, set low effort or turn thinking off, or output costs could be several
  times higher than shown.
- **Label-only services.** Rekognition and Cloud Vision return generic labels ("cat", "person"). They can't answer our
  custom question or read a 4-frame grid, so they're not a direct swap.
- **Accuracy is a separate question.** Run the labeled clips (`cmo_test_data/labeled`) through a candidate before
  switching, the same way qwen3-vl:8b is tested.

**Bottom line:** a cheap cloud model costs a few dollars a month for both cameras, cheap enough to serve as the
fallback for "Cameras in other homes" or for when ada is down. The large models only make sense if accuracy clearly
improves.

## Sources

- Anthropic: Claude model pricing from Anthropic's Claude API reference (cached 2026-10-06)
- [OpenAI API pricing in 2026 (CloudZero)](https://www.cloudzero.com/blog/openai-pricing/)
- [OpenAI API Pricing: Full Breakdown (Puter)](https://developer.puter.com/tutorials/openai-api-pricing/)
- [OpenAI API Pricing — All Models (usagepricing.com)](https://www.usagepricing.com/ai-token-pricing/openai)
- [LLM API Pricing 2026 (IntuitionLabs)](https://intuitionlabs.ai/articles/llm-api-pricing-comparison-2025)
- [Gemini API Pricing (Morph)](https://www.morphllm.com/gemini-api-pricing)
- [Gemini pricing in 2026 (CloudZero)](https://www.cloudzero.com/blog/gemini-pricing/)
- [Google Cloud generative AI pricing](https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing)
- [Gemini 2.5 Flash-Lite pricing (pricepertoken.com)](https://pricepertoken.com/pricing-page/model/google-gemini-2.5-flash-lite)
- [Qwen API Pricing Guide 2026 (DeepInfra)](https://deepinfra.com/blog/qwen-api-pricing-2026-guide)
- [Qwen API Pricing (Puter)](https://developer.puter.com/tutorials/qwen-api-pricing/)
- [Qwen pricing in 2026 (eesel)](https://www.eesel.ai/blog/qwen-pricing)
- [Qwen2.5-VL 72B on Together AI](https://www.together.ai/models/qwen2-5-vl-72b-instruct)
- [Amazon Nova Lite pricing (devtk.ai)](https://devtk.ai/en/models/nova-lite/)
- [Google Cloud Vision pricing](https://cloud.google.com/vision/pricing)
- [Amazon Rekognition pricing 2026 (checkthat.ai)](https://checkthat.ai/brands/amazon-rekognition/pricing)
- [Best Image Recognition APIs 2026 (apiscout)](https://apiscout.dev/guides/best-image-recognition-apis-2026)
