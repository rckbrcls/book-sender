import Foundation

struct FailurePresentationService: Sendable {
    func presentation(for failure: SanitizedFailure) -> FailurePresentation {
        let entry = catalogEntry(for: failure.code)
        let recovery = recoveryAction(
            for: failure.code,
            fallback: failure.recoveryAction
        )
        return FailurePresentation(
            title: entry.title,
            summary: entry.summary,
            explanation: entry.explanation,
            impact: entry.impact,
            code: failure.code,
            family: failure.family,
            phase: failure.evidence.phase,
            providerStatus: failure.evidence.providerStatus,
            retryDisposition: failure.evidence.retryDisposition,
            actionTitle: actionTitle(for: recovery),
            action: recovery,
            copyAvailable: true
        )
    }

    private func catalogEntry(for code: DiagnosticCode) -> CatalogEntry {
        switch code {
        case .deliverySetupValidation:
            CatalogEntry(
                title: "Delivery setup needs attention",
                summary: "Review the highlighted setup fields.",
                explanation: "One or more values do not meet the delivery setup requirements.",
                impact: "The setup was not saved."
            )

        case .intakeCapacity:
            CatalogEntry(
                title: "Batch limit reached",
                summary: "This book was not added because the batch is full.",
                explanation: "Book Sender accepts a bounded number of books in each batch.",
                impact: "The existing batch is unchanged."
            )
        case .intakeDuplicate:
            CatalogEntry(
                title: "Book already added",
                summary: "This book is already in the current batch.",
                explanation: "Book Sender detected the same source and staged content.",
                impact: "A duplicate item was not created."
            )
        case .intakeSize:
            limitEntry(
                title: "Book is outside the size limit",
                object: "book",
                impact: "The book was not added."
            )
        case .intakeUnreadable:
            CatalogEntry(
                title: "Book is not readable",
                summary: "Book Sender cannot read the selected file.",
                explanation: "The selection is not a readable regular file.",
                impact: "The book was not added."
            )
        case .intakeUnsupported:
            CatalogEntry(
                title: "Book format is unsupported",
                summary: "Choose an EPUB or PDF book.",
                explanation: "Book Sender does not convert or deliver other book formats.",
                impact: "The selected file was not added."
            )
        case .intakeChanged:
            CatalogEntry(
                title: "Book changed while being added",
                summary: "Select the book again after changes finish.",
                explanation: "The source changed before Book Sender completed its safe staging check.",
                impact: "The changing source was not used."
            )
        case .intakeFailed:
            unexpectedEntry(
                title: "Book intake failed",
                action: "adding the selected book",
                impact: "The book was not added."
            )

        case .pdfSize:
            limitEntry(
                title: "PDF is outside the delivery limit",
                object: "PDF",
                impact: "The PDF is not ready to send."
            )
        case .pdfSignature:
            CatalogEntry(
                title: "PDF signature is invalid",
                summary: "The file does not begin as a valid PDF.",
                explanation: "Its format marker does not match the selected PDF type.",
                impact: "The file is blocked from delivery."
            )
        case .pdfStructure:
            CatalogEntry(
                title: "PDF is incomplete",
                summary: "The PDF does not have a complete file ending.",
                explanation: "Book Sender stopped before delivery because the document structure is incomplete.",
                impact: "The PDF is blocked from delivery."
            )
        case .pdfCancelled:
            cancelledEntry(
                title: "PDF preparation cancelled",
                impact: "The PDF was not prepared."
            )
        case .pdfRead:
            CatalogEntry(
                title: "PDF cannot be read",
                summary: "Book Sender could not complete the PDF safety check.",
                explanation: "The staged PDF became unavailable during preparation.",
                impact: "The PDF is not ready to send."
            )

        case .archiveOpen:
            archiveEntry(
                title: "EPUB archive cannot be opened",
                summary: "The EPUB container is unreadable.",
                impact: "The EPUB is blocked from preparation."
            )
        case .archiveDuplicatePath:
            archiveEntry(
                title: "EPUB contains duplicate paths",
                summary: "The archive has ambiguous duplicate entries.",
                impact: "The EPUB is blocked for safety."
            )
        case .archiveEncrypted:
            archiveEntry(
                title: "Encrypted EPUB archive is unsupported",
                summary: "Book Sender cannot inspect this encrypted archive.",
                impact: "The EPUB is blocked from preparation."
            )
        case .archiveUnsupportedEntry:
            archiveEntry(
                title: "EPUB contains an unsupported entry",
                summary: "The archive includes an entry type that cannot be processed safely.",
                impact: "The EPUB is blocked for safety."
            )
        case .archiveUnsafePath:
            archiveEntry(
                title: "EPUB contains an unsafe path",
                summary: "An archive entry could escape its isolated workspace.",
                impact: "The EPUB is blocked for safety."
            )
        case .archiveEntryLimit:
            limitEntry(
                title: "EPUB has too many entries",
                object: "archive",
                impact: "The EPUB is blocked from preparation."
            )
        case .archiveSizeLimit:
            limitEntry(
                title: "EPUB archive is too large",
                object: "archive",
                impact: "The EPUB is blocked from preparation."
            )
        case .archiveExpansionRatio:
            limitEntry(
                title: "EPUB expands beyond the safety ratio",
                object: "archive",
                impact: "The EPUB is blocked from extraction."
            )
        case .archiveEntryUnavailable:
            archiveEntry(
                title: "EPUB entry is unavailable",
                summary: "A required archive entry could not be read.",
                impact: "The EPUB audit did not finish."
            )
        case .archiveExtract:
            archiveEntry(
                title: "EPUB extraction failed",
                summary: "A bounded archive entry could not be extracted.",
                impact: "No prepared copy was produced."
            )
        case .archiveTimeout:
            timeoutEntry(
                title: "EPUB archive check timed out",
                action: "archive safety check",
                impact: "The EPUB was not prepared."
            )

        case .xmlByteLimit, .xmlStructureLimit, .xmlTextLimit:
            limitEntry(
                title: "EPUB XML exceeds a safety limit",
                object: "XML document",
                impact: "The EPUB audit stopped safely."
            )
        case .xmlExternalEntity:
            CatalogEntry(
                title: "EPUB XML requests external content",
                summary: "External XML entities are not allowed.",
                explanation: "Book Sender disables external entity resolution to keep preparation local and safe.",
                impact: "The EPUB is blocked from preparation."
            )
        case .xmlInvalid:
            CatalogEntry(
                title: "EPUB XML is malformed",
                summary: "A required EPUB document is not valid XML.",
                explanation: "The structural audit cannot reliably interpret the malformed document.",
                impact: "The EPUB is not ready to send."
            )
        case .xmlTimeout:
            timeoutEntry(
                title: "EPUB XML parsing timed out",
                action: "XML safety check",
                impact: "The EPUB audit did not finish."
            )
        case .xmlCancelled:
            cancelledEntry(
                title: "EPUB XML check cancelled",
                impact: "The EPUB audit did not finish."
            )

        case .repairBlocked:
            repairEntry(
                title: "EPUB needs manual review",
                summary: "The detected issues are not safe to repair automatically.",
                impact: "No working copy was created."
            )
        case .repairRevalidationFailed:
            repairEntry(
                title: "Prepared EPUB did not pass revalidation",
                summary: "The working copy still contains blocking issues.",
                impact: "The working copy will not be delivered."
            )
        case .repairAttachmentSize:
            limitEntry(
                title: "Prepared EPUB exceeds the delivery limit",
                object: "working copy",
                impact: "The EPUB is not ready to send."
            )
        case .repairCancelled:
            cancelledEntry(
                title: "EPUB preparation cancelled",
                impact: "No completed working copy was kept."
            )
        case .repairInvalidPlan:
            repairEntry(
                title: "EPUB repair plan is invalid",
                summary: "The planned working-copy operation is inconsistent.",
                impact: "No working copy was created."
            )
        case .repairUnsupportedAction:
            repairEntry(
                title: "EPUB repair action is unsupported",
                summary: "The requested change is outside the deterministic repair set.",
                impact: "The original remains unchanged."
            )
        case .repairOutputCreate, .repairEntryCreate:
            repairEntry(
                title: "EPUB working copy cannot be created",
                summary: "Book Sender could not create an isolated repair output.",
                impact: "The original remains unchanged."
            )
        case .repairEntryMissing:
            repairEntry(
                title: "EPUB repair source entry is missing",
                summary: "A required entry disappeared before the working copy was written.",
                impact: "No working copy was completed."
            )
        case .repairWrite:
            repairEntry(
                title: "EPUB working copy write failed",
                summary: "Book Sender stopped while writing the isolated copy.",
                impact: "The partial output was discarded."
            )
        case .repairPrecondition:
            repairEntry(
                title: "EPUB repair precondition changed",
                summary: "The archive no longer matches the validated repair plan.",
                impact: "No repair was applied."
            )
        case .repairTimeout:
            timeoutEntry(
                title: "EPUB preparation timed out",
                action: "working-copy write",
                impact: "The partial output was discarded."
            )
        case .repairContainer:
            repairEntry(
                title: "EPUB container restoration failed",
                summary: "The package location could not be restored deterministically.",
                impact: "The EPUB is not ready to send."
            )
        case .repairMimetype:
            repairEntry(
                title: "EPUB package marker repair failed",
                summary: "The required EPUB marker could not be rebuilt safely.",
                impact: "The EPUB is not ready to send."
            )
        case .repairMediaType:
            repairEntry(
                title: "EPUB media type repair failed",
                summary: "A manifest type could not be corrected deterministically.",
                impact: "The EPUB is not ready to send."
            )
        case .repairPath:
            repairEntry(
                title: "EPUB path repair failed",
                summary: "An internal resource path could not be normalized safely.",
                impact: "The EPUB is not ready to send."
            )
        case .repairReference:
            repairEntry(
                title: "EPUB reference repair failed",
                summary: "An internal reference could not be resolved unambiguously.",
                impact: "The EPUB is not ready to send."
            )
        case .repairSpine:
            repairEntry(
                title: "EPUB spine repair failed",
                summary: "A spine entry could not be removed deterministically.",
                impact: "The EPUB is not ready to send."
            )
        case .repairXML:
            repairEntry(
                title: "EPUB XML repair failed",
                summary: "A document could not be normalized deterministically.",
                impact: "The EPUB is not ready to send."
            )
        case .repairFailed:
            unexpectedEntry(
                title: "EPUB preparation failed",
                action: "preparing the working copy",
                impact: "No deliverable working copy was produced."
            )

        case .workspaceCollision:
            workspaceEntry(
                title: "Workspace name collision",
                summary: "A collision-safe working location could not be reserved.",
                impact: "The book was not staged."
            )
        case .workspaceInvalidMarker, .workspaceInvalidPath:
            workspaceEntry(
                title: "Workspace validation failed",
                summary: "The isolated working location did not pass its safety check.",
                impact: "Book processing stopped before using the location."
            )
        case .workspaceMarker:
            workspaceEntry(
                title: "Workspace marker cannot be written",
                summary: "Book Sender could not establish a verified isolated workspace.",
                impact: "The book was not staged."
            )
        case .workspaceCopy:
            workspaceEntry(
                title: "Book staging failed",
                summary: "The selected book could not be copied into the isolated workspace.",
                impact: "The original was not modified."
            )
        case .workspacePartialCreate:
            workspaceEntry(
                title: "Partial file cannot be created",
                summary: "Book Sender could not create a bounded temporary output.",
                impact: "No prepared copy was produced."
            )
        case .workspacePromote:
            workspaceEntry(
                title: "Prepared copy cannot be finalized",
                summary: "The validated partial output could not be promoted.",
                impact: "The book is not ready to send."
            )
        case .workspaceSizeLimit:
            limitEntry(
                title: "Workspace copy exceeds a safety limit",
                object: "staged book",
                impact: "The copy was discarded."
            )
        case .workspaceTimeout:
            timeoutEntry(
                title: "Workspace operation timed out",
                action: "isolated file operation",
                impact: "The incomplete output was discarded."
            )
        case .pipelineMissingStagedSource:
            workspaceEntry(
                title: "Staged book is missing",
                summary: "The preparation pipeline cannot find its isolated source.",
                impact: "This book is not ready to send."
            )
        case .pipelinePreparationResult:
            unexpectedEntry(
                title: "Book preparation returned no result",
                action: "finalizing book preparation",
                impact: "This book is not ready to send."
            )

        case .credentialEmpty:
            credentialEntry(
                title: "App password is required",
                summary: "Enter a non-empty app password.",
                impact: "Delivery setup was not saved."
            )
        case .credentialMissing:
            credentialEntry(
                title: "Stored app password is missing",
                summary: "Enter the app password again.",
                impact: "Delivery cannot start until setup is repaired."
            )
        case .credentialRead:
            credentialEntry(
                title: "App password cannot be read",
                summary: "The saved Keychain credential is unavailable.",
                impact: "Delivery did not start."
            )
        case .credentialSave, .credentialUITest:
            credentialEntry(
                title: "App password was not stored",
                summary: "Keychain did not accept the credential update.",
                impact: "Delivery setup was not saved."
            )
        case .credentialDelete:
            credentialEntry(
                title: "Stored app password was not removed",
                summary: "Keychain did not complete credential deletion.",
                impact: "Review Keychain before considering setup removal complete."
            )
        case .preferencesInvalid:
            credentialEntry(
                title: "Saved delivery settings are invalid",
                summary: "Enter the delivery setup again.",
                impact: "Book Sender opened the setup screen instead of sending."
            )
        case .preferencesInvalidRevision:
            credentialEntry(
                title: "Delivery settings were not saved",
                summary: "The setup revision could not be persisted consistently.",
                impact: "The previous saved setup remains active."
            )

        case .mimeHeaderInjection:
            CatalogEntry(
                title: "Book name is unsafe for email",
                summary: "The attachment name contains an invalid header value.",
                explanation: "Book Sender blocks header injection before creating the message.",
                impact: "No message was sent."
            )
        case .smtpAttachmentSize:
            limitEntry(
                title: "Attachment exceeds the delivery limit",
                object: "attachment",
                impact: "No SMTP connection was started."
            )
        case .smtpCommandSize:
            limitEntry(
                title: "SMTP authentication value is too large",
                object: "authentication command",
                impact: "No credential was transmitted."
            )
        case .smtpConnectionClosed:
            smtpEntry(
                title: "SMTP connection closed early",
                summary: "The secure delivery connection ended before completion.",
                impact: "The result depends on whether message transmission had started."
            )
        case .smtpTransport:
            smtpEntry(
                title: "SMTP connection failed",
                summary: "Book Sender lost the delivery transport.",
                impact: "The result depends on whether message transmission had started."
            )
        case .smtpTimeout:
            smtpEntry(
                title: "SMTP step timed out",
                summary: "The provider did not complete the active delivery phase in time.",
                impact: "The result depends on whether message transmission had started."
            )
        case .smtpSecureChannel:
            smtpEntry(
                title: "Secure SMTP channel failed",
                summary: "TLS could not establish a verified connection.",
                impact: "Authentication and message data were not sent."
            )
        case .smtpGreeting:
            smtpEntry(
                title: "SMTP greeting was not accepted",
                summary: "The provider did not open a usable SMTP session.",
                impact: "Authentication and message data were not sent."
            )
        case .smtpEHLO, .smtpSecureEHLO:
            smtpEntry(
                title: "SMTP capabilities are unavailable",
                summary: "The provider did not complete capability negotiation.",
                impact: "Authentication did not start."
            )
        case .smtpStartTLS, .smtpStartTLSState:
            smtpEntry(
                title: "STARTTLS negotiation failed",
                summary: "The connection could not transition to the required secure state.",
                impact: "Authentication did not start."
            )
        case .smtpStartTLSUnavailable:
            smtpEntry(
                title: "SMTP server does not offer STARTTLS",
                summary: "The configured server cannot satisfy the selected security mode.",
                impact: "Book Sender stopped before authentication."
            )
        case .smtpAuthenticationUnavailable:
            smtpEntry(
                title: "Supported SMTP authentication is unavailable",
                summary: "The secured server did not offer PLAIN or LOGIN authentication.",
                impact: "The app password was not sent."
            )
        case .smtpAuthenticationRejected:
            smtpEntry(
                title: "SMTP authentication was rejected",
                summary: "Verify the account and app password in Delivery Setup.",
                impact: "The provider did not accept the sender session."
            )
        case .smtpSenderRejected:
            smtpEntry(
                title: "Sender address was rejected",
                summary: "The provider did not accept the configured sender.",
                impact: "The recipient and book data were not sent."
            )
        case .smtpRecipientRejected:
            smtpEntry(
                title: "Kindle recipient was rejected",
                summary: "Verify the Kindle address and approved-sender settings.",
                impact: "The book data was not sent."
            )
        case .smtpDataRejected:
            smtpEntry(
                title: "Provider refused message data",
                summary: "The SMTP DATA command was not accepted.",
                impact: "Book transmission did not begin."
            )
        case .smtpFinalAcceptanceRejected:
            smtpEntry(
                title: "Provider rejected the transmitted book",
                summary: "The final SMTP acceptance reply was a rejection.",
                impact: "The rejection is conclusive; the book was not submitted."
            )
        case .smtpDeliveryUnknown:
            smtpEntry(
                title: "Delivery result is unknown",
                summary: "Check Kindle before retrying this book.",
                impact: "The provider may have accepted message data before the connection ended."
            )
        case .smtpReplyCode, .smtpReplyCount, .smtpReplyFormat, .smtpReplyLine:
            smtpEntry(
                title: "SMTP response is malformed",
                summary: "The provider response did not satisfy bounded SMTP framing.",
                impact: "Book Sender stopped without using provider-controlled text."
            )
        case .smtpUITestRejected:
            smtpEntry(
                title: "Controlled SMTP rejection",
                summary: "The isolated test transport returned a delivery rejection.",
                impact: "The test book was not submitted."
            )
        case .deliveryFailed:
            unexpectedEntry(
                title: "Book delivery failed",
                action: "delivering the book",
                impact: "The book was not submitted."
            )

        case .shortcutConflict:
            CatalogEntry(
                title: "Shortcut is unavailable",
                summary: "Choose a different global shortcut.",
                explanation: "The selected key combination is not registered for Book Sender.",
                impact: "The existing app window can still be opened normally."
            )
        case .clipboardWrite:
            CatalogEntry(
                title: "Error details were not copied",
                summary: "The pasteboard did not accept the sanitized diagnostic text.",
                explanation: "The original error details remain visible for manual reading.",
                impact: "The clipboard was not changed by Book Sender."
            )
        case .historyUnavailable:
            historyEntry(
                title: "Send history is unavailable",
                summary: "Book Sender could not open the local submission record.",
                impact: "Sending remains available, but history is not currently visible."
            )
        case .historyRead:
            historyEntry(
                title: "Send history cannot be read",
                summary: "The local submission record could not be loaded.",
                impact: "Sending remains available and the existing history file was not changed."
            )
        case .historyDecode:
            historyEntry(
                title: "Send history is unreadable",
                summary: "The local submission record does not match its expected format.",
                impact: "Book Sender did not repair or overwrite the existing history file."
            )
        case .historyUnsupportedSchema:
            historyEntry(
                title: "Send history is from an unsupported version",
                summary: "This app version cannot safely read the local history schema.",
                impact: "Book Sender left the existing history file unchanged."
            )
        case .historyLimit:
            historyEntry(
                title: "Send history exceeds its safety limit",
                summary: "The local submission record is larger than Book Sender accepts.",
                impact: "The oversized history was not loaded or changed."
            )
        case .historyWrite:
            historyEntry(
                title: "Submission was sent but not recorded",
                summary: "The SMTP provider accepted the book, but local history could not be updated.",
                impact: "The successful submission remains definitive and is not retried."
            )
        case .historyClear:
            historyEntry(
                title: "Send history was not cleared",
                summary: "Book Sender could not remove the local submission record.",
                impact: "The existing history entries remain available."
            )
        case .startupBootstrap:
            CatalogEntry(
                title: "Book Sender did not finish opening",
                summary: "Startup restoration stopped at a safe boundary.",
                explanation: "The app could not restore a consistent setup and workspace state.",
                impact: "Sending remains unavailable until the startup issue is resolved."
            )
        case .updateConfiguration:
            CatalogEntry(
                title: "Update check is unavailable",
                summary: "Sparkle could not start the standard update cycle.",
                explanation: "The configured update service is unavailable in this app build.",
                impact: "The current app version continues to run."
            )

        case .unexpectedIntake:
            unexpectedEntry(
                title: "Unexpected book intake failure",
                action: "adding the book",
                impact: "The book was not added."
            )
        case .unexpectedArchive:
            unexpectedEntry(
                title: "Unexpected archive failure",
                action: "checking the EPUB archive",
                impact: "The EPUB is not ready to send."
            )
        case .unexpectedXML:
            unexpectedEntry(
                title: "Unexpected XML failure",
                action: "checking EPUB XML",
                impact: "The EPUB audit did not finish."
            )
        case .unexpectedAudit:
            unexpectedEntry(
                title: "Unexpected EPUB audit failure",
                action: "auditing the EPUB structure",
                impact: "The EPUB is not ready to send."
            )
        case .unexpectedRepair:
            unexpectedEntry(
                title: "Unexpected EPUB repair failure",
                action: "preparing the EPUB working copy",
                impact: "No deliverable working copy was produced."
            )
        case .unexpectedFilesystem:
            unexpectedEntry(
                title: "Unexpected workspace failure",
                action: "using the isolated workspace",
                impact: "Book processing stopped safely."
            )
        case .unexpectedCredential:
            unexpectedEntry(
                title: "Unexpected credential failure",
                action: "accessing secure delivery setup",
                impact: "Delivery setup or sending did not complete."
            )
        case .unexpectedDelivery:
            unexpectedEntry(
                title: "Unexpected delivery failure",
                action: "delivering the book",
                impact: "The book was not confirmed as submitted."
            )
        case .unexpectedShortcut:
            unexpectedEntry(
                title: "Unexpected shortcut failure",
                action: "updating the global shortcut",
                impact: "The shortcut change did not complete."
            )
        }
    }

    private func recoveryAction(
        for code: DiagnosticCode,
        fallback: RecoveryAction?
    ) -> RecoveryAction? {
        switch code {
        case .smtpDeliveryUnknown:
            .confirmUnknownRetry
        case .smtpAuthenticationUnavailable, .smtpSecureChannel,
             .smtpStartTLS, .smtpStartTLSState, .smtpStartTLSUnavailable,
             .smtpEHLO, .smtpSecureEHLO, .smtpGreeting, .credentialEmpty,
             .credentialMissing, .credentialRead, .credentialSave,
             .preferencesInvalid, .preferencesInvalidRevision,
             .deliverySetupValidation:
            .editSetup
        case .smtpAuthenticationRejected, .smtpSenderRejected,
             .smtpRecipientRejected:
            fallback ?? .editSetup
        case .smtpDataRejected, .smtpFinalAcceptanceRejected:
            fallback ?? .retryFailed
        case .smtpTimeout, .smtpTransport, .smtpConnectionClosed, .smtpReplyCode,
             .smtpReplyCount, .smtpReplyFormat, .smtpReplyLine,
             .deliveryFailed, .smtpUITestRejected:
            .retryFailed
        case .intakeCapacity, .intakeChanged, .intakeDuplicate, .intakeFailed,
             .intakeSize, .intakeUnreadable, .intakeUnsupported, .pdfRead,
             .pdfSignature, .pdfSize, .pdfStructure, .smtpAttachmentSize,
             .mimeHeaderInjection, .unexpectedIntake:
            .chooseAnotherFile
        case .shortcutConflict, .unexpectedShortcut:
            .chooseAnotherShortcut
        case .historyUnavailable, .historyRead, .historyDecode,
             .historyUnsupportedSchema, .historyLimit:
            .retryHistoryLoad
        case .historyClear:
            .retryHistoryClear
        case .historyWrite:
            fallback
        case .archiveDuplicatePath, .archiveEncrypted, .archiveEntryLimit,
             .archiveEntryUnavailable, .archiveExpansionRatio, .archiveExtract,
             .archiveOpen, .archiveSizeLimit, .archiveTimeout,
             .archiveUnsafePath, .archiveUnsupportedEntry, .xmlByteLimit,
             .xmlExternalEntity, .xmlInvalid, .xmlStructureLimit, .xmlTextLimit,
             .xmlTimeout, .repairAttachmentSize, .repairBlocked,
             .repairContainer, .repairEntryCreate, .repairEntryMissing,
             .repairFailed, .repairInvalidPlan, .repairMediaType,
             .repairMimetype, .repairOutputCreate, .repairPath,
             .repairPrecondition, .repairReference, .repairRevalidationFailed,
             .repairSpine, .repairTimeout, .repairUnsupportedAction,
             .repairWrite, .repairXML,
             .workspaceCollision, .workspaceCopy, .workspaceInvalidMarker,
             .workspaceInvalidPath, .workspaceMarker, .workspacePartialCreate,
             .workspacePromote, .workspaceSizeLimit, .workspaceTimeout,
             .pipelineMissingStagedSource, .pipelinePreparationResult,
             .unexpectedArchive, .unexpectedXML, .unexpectedAudit,
             .unexpectedRepair, .unexpectedFilesystem:
            .reviewBook
        case .pdfCancelled, .repairCancelled, .xmlCancelled,
             .credentialDelete, .credentialUITest, .smtpCommandSize,
             .clipboardWrite, .startupBootstrap, .updateConfiguration,
             .unexpectedCredential, .unexpectedDelivery:
            fallback
        }
    }

    private func actionTitle(for action: RecoveryAction?) -> String? {
        switch action {
        case .editSetup: "Edit Setup"
        case .chooseAnotherFile: "Choose Another File"
        case .reviewBook: "Review Details"
        case .retryFailed: "Retry"
        case .confirmUnknownRetry: "Check Kindle Before Retrying"
        case .chooseAnotherShortcut: "Choose Another Shortcut"
        case .retryHistoryLoad: "Retry History"
        case .retryHistoryClear: "Try Clearing Again"
        case nil: nil
        }
    }

    private func historyEntry(
        title: String,
        summary: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: summary,
            explanation: "Send history is a bounded local record stored separately from delivery setup and temporary batches.",
            impact: impact
        )
    }

    private func archiveEntry(
        title: String,
        summary: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: summary,
            explanation: "The bounded EPUB archive safety check stopped before unsafe data could be used.",
            impact: impact
        )
    }

    private func repairEntry(
        title: String,
        summary: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: summary,
            explanation: "Book Sender only applies deterministic changes to an isolated working copy.",
            impact: impact
        )
    }

    private func workspaceEntry(
        title: String,
        summary: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: summary,
            explanation: "The isolated filesystem boundary rejected an incomplete or unsafe operation.",
            impact: impact
        )
    }

    private func credentialEntry(
        title: String,
        summary: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: summary,
            explanation: "Book Sender keeps SMTP credentials only in the traditional macOS Keychain.",
            impact: impact
        )
    }

    private func smtpEntry(
        title: String,
        summary: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: summary,
            explanation: "Only the safe SMTP phase and validated numeric status are retained; provider text is discarded.",
            impact: impact
        )
    }

    private func limitEntry(
        title: String,
        object: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: "The \(object) exceeded a bounded safety limit.",
            explanation: "Book Sender stopped the operation before exceeding its local processing limits.",
            impact: impact
        )
    }

    private func timeoutEntry(
        title: String,
        action: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: "The \(action) exceeded its bounded time limit.",
            explanation: "Book Sender stopped the active work instead of waiting indefinitely.",
            impact: impact
        )
    }

    private func cancelledEntry(
        title: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: "The active operation received a cancellation request.",
            explanation: "Pending work was stopped cooperatively at a safe boundary.",
            impact: impact
        )
    }

    private func unexpectedEntry(
        title: String,
        action: String,
        impact: String
    ) -> CatalogEntry {
        CatalogEntry(
            title: title,
            summary: "Book Sender stopped at the safe boundary for \(action).",
            explanation: "The underlying technical error was discarded and replaced with bounded diagnostic evidence.",
            impact: impact
        )
    }
}

private struct CatalogEntry {
    let title: String
    let summary: String
    let explanation: String
    let impact: String
}
