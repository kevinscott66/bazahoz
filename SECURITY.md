# Security Policy

## Supported version

Security fixes target the current `main` branch and the production release linked from the repository homepage.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting for findings that could affect user data, authentication, authorization, or production availability. Do not open a public issue containing exploit details, credentials, personal data, or reproduction artifacts with sensitive content.

Include the affected component, impact, reproduction steps, and any suggested remediation. Reports will be acknowledged after triage and coordinated disclosure will be preferred when a fix is required.

## Scope

The Supabase publishable key embedded in the web client is intentionally public. Access control is enforced with authentication and row-level security. Service-role keys, database credentials, mail provisioning secrets, signing material, and deployment credentials must never be committed.
