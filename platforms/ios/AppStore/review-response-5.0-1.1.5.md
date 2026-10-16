Thank you for reviewing XSIME 1.1.5 (59). We would like to clarify the optional user-configured interface and request reconsideration of the Guideline 5 finding.

XSIME is an independent keyboard and text assistant. Ordinary typing and Buffer editing work offline without an account or Full Access. The app does not bundle a chatbot account, provider credentials, an AI subscription, a preset service endpoint or a preset model, and we do not operate a hosted AI service.

The optional connection uses a general-purpose interface format: the user enters an HTTPS endpoint, model and API key. JSON model/messages fields are sent to that endpoint's chat/completions path only when the user explicitly runs an AI action after granting recipient consent. The previous provider-brand wording described this interface format; it did not describe affiliation or a bundled service. Apple on-device translation is a separate feature and does not fall back to an external service.

We have removed the provider-brand reference from the English, Simplified Chinese and Traditional Chinese App Store descriptions and updated the Review Notes to use "general-purpose interface format." We continue to disclose the optional external AI capability and its data flow.

For clarity, this is a metadata-only clarification for the existing build 59. We have not disabled the user-configured connection, added a China-specific endpoint restriction or replaced the binary. The compatibility explanation in the build's AI Services screen is unchanged. We are not claiming that a functional restriction has already been implemented.

Could you please reconsider the distinction between a user-configured generic interface and a bundled third-party AI service? If additional functional restrictions are required for China mainland distribution, please let us know which behavior must change so we can address it accurately.

Thank you.
