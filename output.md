"""Production-grade exception hierarchy for the AgentArena integration.

Every failure mode of the AgentArena client is mapped onto exactly one node of
this hierarchy so that call sites can react to *categories* of failure instead
of matching on message strings, while still receiving a machine-readable
``code`` and a structured, redacted ``context`` payload.

Design rules
------------
* **Never leak secrets.** Messages and context pass through :func:`sanitize_message`
  and :func:`sanitize_value`; anything whose key looks like a credential is
  replaced by ``***``.
* **Never raise from error construction.** A defensive ``try/except`` guards every
  sanitisation step so that building an exception can never mask the original
  failure.
* **Retry semantics are declared, not guessed.** ``retryable`` and
  ``retry_after`` are class/instance attributes consulted by the retry loop.
* **Cheap to log.** The rendered string is cached at construction time and the
  context mapping is an immutable ``MappingProxyType`` capped at 16 items.
"""