/* Author: test */
﻿USE [CDIO_MeditechDB];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/*
    Preliminary FCAP 1A Treatment Plan build

    Scope retained as separate, explicitly labelled clinical source families:
      1. EMR problem-oriented plans from EmrPatPlan_*
      2. Clinical-document problem-instance plans from EmrClinDoc_ProbInstPlans_*
      3. Patient Care System care plans from PcsAcct_Plans
      4. Oncology treatment plans from OncPlan_Main

    Deliberate exclusions from the parent Treatment Plan table:
      - PhaRxProtocols and PhaRxProtocolsText: medication-level protocol content
      - OncHimRec_TreatmentSummary: retrospective treatment summary, not a plan
      - OncPlan_Orders detail rows: represented by a count only.
      - OncCycle_Procedures detail rows: deferred pending alignment with the
        Procedures and Infusions topics.
      - PcsAcct_Problems: PcsAcct_ProbPlans is empty, so a direct plan-problem link
        cannot currently be asserted

    Date policy:
      - Lifetime extraction is the default because treatment plans are longitudinal.
      - An optional clinical-date window can be enabled with @ApplyDateWindow = 1.
      - RowUpdateDateTime is never treated as the preferred clinical date. It is used
        only as the final fallback and is explicitly flagged for review.

    Collation policy:
      - All linked-server text used in local temporary tables is explicitly
        converted to DATABASE_DEFAULT before comparison or aggregation.
      - All explicit staging text columns also use DATABASE_DEFAULT rather
        than inheriting the tempdb server collation.
      - This prevents AKULiveATdb/tempdb collation conflicts in COALESCE,
        LEFT, joins, concatenation, and final publication.

    Hash policy:
      - hashkey is the final output column and is classified as NON_PHI.
      - SHA-256 input follows the Phase 2 record-key pattern:
        PatientID + TreatmentPlanID + ClinicalDateTime.
      - The hashkey is a technical row key and does not replace the de-identified
        patient identifier.

	Built By:
		- Yours Truly Allan Z.
		- Year of the Lord 2026 
*/

CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_TreatmentPlans_Extended]
    @ApplyDateWindow BIT = 0,
    @WindowStart     DATE = '2022-11-05',
    @WindowEnd       DATE = '2026-06-14',
    @IncludeUndated  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @RunStart                    DATETIME = SYSDATETIME(),
        @RunEnd                      DATETIME,
        @ExtractedOn                 DATETIME = SYSDATETIME(),
        @WindowEndPlus1              DATE,
        @DurationSeconds             INT,
        @TotalEligible               INT = 0,
        @RecordCount                 BIGINT = 0,
        @RecordCountForLog           INT = NULL,
        @EmrProblemPlanCount         BIGINT = 0,
        @EmrDocumentPlanCount        BIGINT = 0,
        @PcsCarePlanCount            BIGINT = 0,
        @OncologyPlanCount           BIGINT = 0,
        @ReviewCount                 BIGINT = 0,
        @ErrorMessage                NVARCHAR(4000),
        @Remarks                     NVARCHAR(4000);

    IF @ApplyDateWindow IS NULL OR @ApplyDateWindow NOT IN (0, 1)
        THROW 53100, '@ApplyDateWindow must be 0 or 1.', 1;

    IF @IncludeUndated IS NULL OR @IncludeUndated NOT IN (0, 1)
        THROW 53101, '@IncludeUndated must be 0 or 1.', 1;

    IF @ApplyDateWindow = 1
       AND (@WindowStart IS NULL OR @WindowEnd IS NULL OR @WindowEnd < @WindowStart)
        THROW 53102, 'A valid date window is required when @ApplyDateWindow = 1.', 1;

    SET @WindowEndPlus1 = DATEADD(DAY, 1, @WindowEnd);

    IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended', 'U') IS NULL
        THROW 53103, 'dbo.tbl_FCAP1A_Cohort10_Extended does not exist.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended')
          AND name = 'PatientID'
    )
        THROW 53104, 'dbo.tbl_FCAP1A_Cohort10_Extended does not contain PatientID.', 1;

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log', 'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log
        (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME         NOT NULL,
            RunEnd          DATETIME         NULL,
            DurationSeconds INT              NULL,
            RunStatus       VARCHAR(20)      NOT NULL,
            DataTopic       NVARCHAR(100)    NOT NULL,
            WindowStart     DATE             NULL,
            WindowEnd       DATE             NULL,
            TotalEligible   INT              NULL,
            RecordCount     INT              NULL,
            ProcessedBy     NVARCHAR(100)    NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000)   NULL,
            Remarks         NVARCHAR(4000)   NULL
        );
    END;

    BEGIN TRY
        /*==============================================================
          1. Cohort and encounter/account spine
        ==============================================================*/

        IF OBJECT_ID('tempdb..#Cohort') IS NOT NULL DROP TABLE #Cohort;
        CREATE TABLE #Cohort
        (
            PatientID NVARCHAR(255) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY
        );

        INSERT INTO #Cohort (PatientID)
        SELECT DISTINCT
            CONVERT(NVARCHAR(255), PatientID) COLLATE DATABASE_DEFAULT
        FROM dbo.tbl_FCAP1A_Cohort10_Extended
        WHERE PatientID IS NOT NULL;

        SELECT @TotalEligible = COUNT(*) FROM #Cohort;

        IF @TotalEligible = 0
            THROW 53105, 'The FCAP 1A cohort is empty.', 1;

        IF OBJECT_ID('tempdb..#RegAcctCohort') IS NOT NULL DROP TABLE #RegAcctCohort;

        ;WITH RankedAccounts AS
        (
            SELECT
                CONVERT(NVARCHAR(10), r.SourceID) COLLATE DATABASE_DEFAULT AS SourceID,
                CONVERT(NVARCHAR(50), r.VisitID) COLLATE DATABASE_DEFAULT AS VisitID,
                CONVERT(NVARCHAR(50), r.PatientID) COLLATE DATABASE_DEFAULT AS PatientID,
                r.ServiceDateTime,
                r.AdmitDateTime,
                r.ArrivalDateTime,
                CONVERT(NVARCHAR(100), r.Facility_MisFacID) COLLATE DATABASE_DEFAULT AS FacilityID,
                CONVERT(NVARCHAR(100), r.Location_MisLocID) COLLATE DATABASE_DEFAULT AS LocationID,
                CONVERT(NVARCHAR(100), r.ServiceInpatient_MisSvcID) COLLATE DATABASE_DEFAULT AS ServiceInpatientID,
                CONVERT(NVARCHAR(100), r.ServiceOutpatient_MisSvcID) COLLATE DATABASE_DEFAULT AS ServiceOutpatientID,
                r.RowUpdateDateTime,
                ROW_NUMBER() OVER
                (
                    PARTITION BY r.SourceID, r.VisitID
                    ORDER BY r.RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[RegAcct_Main] AS r
            INNER JOIN #Cohort AS c
                ON CONVERT(NVARCHAR(50), r.PatientID) COLLATE DATABASE_DEFAULT = c.PatientID
            WHERE r.PatientID IS NOT NULL
        )
        SELECT
            SourceID,
            VisitID,
            PatientID,
            ServiceDateTime,
            AdmitDateTime,
            ArrivalDateTime,
            FacilityID,
            LocationID,
            ServiceInpatientID,
            ServiceOutpatientID,
            RowUpdateDateTime
        INTO #RegAcctCohort
        FROM RankedAccounts
        WHERE rn = 1;

        CREATE UNIQUE CLUSTERED INDEX IX_RegAcctCohort_SourceVisit
            ON #RegAcctCohort (SourceID, VisitID);

        CREATE INDEX IX_RegAcctCohort_Patient
            ON #RegAcctCohort (PatientID);

        /*==============================================================
          2. Unified stage table
        ==============================================================*/

        IF OBJECT_ID('tempdb..#TreatmentPlanStage') IS NOT NULL DROP TABLE #TreatmentPlanStage;

        CREATE TABLE #TreatmentPlanStage
        (
            PatientID                       NVARCHAR(255) COLLATE DATABASE_DEFAULT  NOT NULL,
            VisitID                         NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            VisitLinkType                   NVARCHAR(60) COLLATE DATABASE_DEFAULT   NULL,
            SourceID                        NVARCHAR(50) COLLATE DATABASE_DEFAULT   NOT NULL,
            TreatmentPlanSourceType         NVARCHAR(80) COLLATE DATABASE_DEFAULT   NOT NULL,
            TreatmentPlanID                 NVARCHAR(450) COLLATE DATABASE_DEFAULT  NOT NULL,
            SourcePlanID                    NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            SourcePlanDictionaryID          NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            SourceDocumentID                NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            SourceProblemID                 NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            FirstCycleID                    NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            PlanName                        NVARCHAR(500) COLLATE DATABASE_DEFAULT  NULL,
            PlanType                        NVARCHAR(150) COLLATE DATABASE_DEFAULT  NULL,
            PlanStatus                      NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            ProblemLabelText                NVARCHAR(MAX) COLLATE DATABASE_DEFAULT  NULL,
            ProblemDictionaryName           NVARCHAR(500) COLLATE DATABASE_DEFAULT  NULL,
            ProblemDictionarySource         NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            DiagnosisID                     NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            DiagnosisName                   NVARCHAR(500) COLLATE DATABASE_DEFAULT  NULL,
            IndicationID                    NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            IndicationName                  NVARCHAR(500) COLLATE DATABASE_DEFAULT  NULL,
            ClinicID                        NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            ClinicName                      NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            DocumentType                    NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            DocumentName                    NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            DocumentStatus                  NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            DocumentPlanMode                NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            PlanAuthorUserID                NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            PlanCompletedByUserID           NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            PlanStoppedByUserID             NVARCHAR(255) COLLATE DATABASE_DEFAULT  NULL,
            ClinicalDateTime                DATETIME       NULL,
            ClinicalDateSource              NVARCHAR(150) COLLATE DATABASE_DEFAULT  NULL,
            PlanCreatedDateTime             DATETIME       NULL,
            PlanStartDateTime               DATETIME       NULL,
            PlanEndDateTime                 DATETIME       NULL,
            PlanInitializedDateTime         DATETIME       NULL,
            PlanCompletedDateTime           DATETIME       NULL,
            PlanStoppedDateTime             DATETIME       NULL,
            FirstPlannedActivityDateTime    DATETIME       NULL,
            LastPlannedActivityDateTime     DATETIME       NULL,
            FirstActualActivityDateTime     DATETIME       NULL,
            LastActualActivityDateTime      DATETIME       NULL,
            LastPlanActivityDateTime        DATETIME       NULL,
            FacilityID                      NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            LocationID                      NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            ServiceInpatientID              NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            ServiceOutpatientID             NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            ConfidentialFlag                NVARCHAR(10) COLLATE DATABASE_DEFAULT   NULL,
            KeyIndicator                    NVARCHAR(10) COLLATE DATABASE_DEFAULT   NULL,
            PlanLength                      INT            NULL,
            PlanLengthOfStay                INT            NULL,
            PlanLevelType                   NVARCHAR(50) COLLATE DATABASE_DEFAULT   NULL,
            PlanWeightValue                 NVARCHAR(50) COLLATE DATABASE_DEFAULT   NULL,
            PlanWeightAlternateUnit          NVARCHAR(50) COLLATE DATABASE_DEFAULT   NULL,
            PlanWeightDateTime              DATETIME       NULL,
            BsaMethod                       NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            PlanItemCount                   BIGINT         NULL,
            PlannedCycleCount               BIGINT         NULL,
            CycleCount                      BIGINT         NULL,
            OrderCount                      BIGINT         NULL,
            PlanActivityCount               BIGINT         NULL,
            PlanTextLineCount               BIGINT         NULL,
            MedicationTextLineCount         BIGINT         NULL,
            OrderTextLineCount              BIGINT         NULL,
            PlanNarrativeText               NVARCHAR(MAX) COLLATE DATABASE_DEFAULT  NULL,
            PlannedMedicationText           NVARCHAR(MAX) COLLATE DATABASE_DEFAULT  NULL,
            PlannedOrderText                NVARCHAR(MAX) COLLATE DATABASE_DEFAULT  NULL,
            ProtocolText                    NVARCHAR(MAX) COLLATE DATABASE_DEFAULT  NULL,
            PlanTextSource                  NVARCHAR(100) COLLATE DATABASE_DEFAULT  NULL,
            ClinicalPlausibilityFlag        VARCHAR(20) COLLATE DATABASE_DEFAULT    NOT NULL,
            ClinicalPlausibilityIssue       NVARCHAR(1000) COLLATE DATABASE_DEFAULT NULL,
            SourceRowUpdateDateTime          DATETIME       NULL,
            ExtractedFrom                   NVARCHAR(1000) COLLATE DATABASE_DEFAULT NOT NULL,
            ExtractedOn                     DATETIME       NOT NULL
        );

        /*==============================================================
          3. EMR problem-oriented plans

          Grain:
            SourceID + PatientID + UserID + VisitID + DocumentID + ProblemID

          Inclusion rule:
            At least one non-blank plan, planned-medication, or planned-order
            text line must exist. Label-only rows are not promoted as plans.
        ==============================================================*/

        IF OBJECT_ID('tempdb..#EmrProblemBase') IS NOT NULL DROP TABLE #EmrProblemBase;

        ;WITH NormalizedEmrProblems AS
        (
            SELECT
                LTRIM(RTRIM(CONVERT(NVARCHAR(3), p.SourceID)))
                    COLLATE DATABASE_DEFAULT AS SourceID,
                LTRIM(RTRIM(CONVERT(NVARCHAR(30), p.PatientID)))
                    COLLATE DATABASE_DEFAULT AS PatientID,
                LTRIM(RTRIM(CONVERT(NVARCHAR(25), p.User_UnvUserID)))
                    COLLATE DATABASE_DEFAULT AS PlanUserID,
                LTRIM(RTRIM(CONVERT(NVARCHAR(40), p.VisitID)))
                    COLLATE DATABASE_DEFAULT AS VisitID,
                LTRIM(RTRIM(CONVERT(NVARCHAR(40), p.Document_EmrClinDocID)))
                    COLLATE DATABASE_DEFAULT AS DocumentID,
                LTRIM(RTRIM(CONVERT(NVARCHAR(48), p.Problem_MisPatProblemID)))
                    COLLATE DATABASE_DEFAULT AS ProblemID,
                p.RowUpdateDateTime AS ProblemRowUpdateDateTime,

                CONVERT(NVARCHAR(100), d.DocumentType) COLLATE DATABASE_DEFAULT AS DocumentType,
                CONVERT(NVARCHAR(255), d.DocumentName) COLLATE DATABASE_DEFAULT AS DocumentName,
                CONVERT(NVARCHAR(100), d.ZoldStatus) COLLATE DATABASE_DEFAULT AS DocumentStatus,
                CONVERT(NVARCHAR(100), d.DocumentPlanMode) COLLATE DATABASE_DEFAULT AS DocumentPlanMode,
                d.DateTime AS DocumentDateTime,
                d.CreatedDateTime AS DocumentCreatedDateTime,
                d.LastSaveDateTime AS DocumentLastSaveDateTime,
                CONVERT(NVARCHAR(255), d.CreatedBy_UnvUserID) COLLATE DATABASE_DEFAULT AS DocumentCreatedByUserID,
                CONVERT(NVARCHAR(255), d.LastSaveUser_UnvUserID) COLLATE DATABASE_DEFAULT AS DocumentLastSaveUserID,
                d.RowUpdateDateTime AS DocumentRowUpdateDateTime,

                CONVERT(NVARCHAR(500), mp.Name) COLLATE DATABASE_DEFAULT AS ProblemDictionaryName,
                CONVERT(NVARCHAR(100), mp.Source) COLLATE DATABASE_DEFAULT AS ProblemDictionarySource,
                mp.RowUpdateDateTime AS ProblemDictionaryRowUpdateDateTime,

                a.ServiceDateTime,
                a.AdmitDateTime,
                a.ArrivalDateTime,
                a.FacilityID,
                a.LocationID,
                a.ServiceInpatientID,
                a.ServiceOutpatientID,
                a.RowUpdateDateTime AS AccountRowUpdateDateTime

            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPatPlan_Problems] AS p
            INNER JOIN #Cohort AS c
                ON LTRIM(RTRIM(CONVERT(NVARCHAR(30), p.PatientID)))
                   COLLATE DATABASE_DEFAULT = c.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrClinDoc_Main] AS d
                ON d.SourceID = p.SourceID
               AND d.EmrClinDocID = p.Document_EmrClinDocID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[MisPatProblem_Main] AS mp
                ON mp.SourceID = p.SourceID
               AND LTRIM(RTRIM(CONVERT(NVARCHAR(48), mp.MisPatProblemID)))
                   COLLATE DATABASE_DEFAULT =
                   LTRIM(RTRIM(CONVERT(NVARCHAR(48), p.Problem_MisPatProblemID)))
                   COLLATE DATABASE_DEFAULT
            LEFT JOIN #RegAcctCohort AS a
                ON a.SourceID = LTRIM(RTRIM(CONVERT(NVARCHAR(3), p.SourceID)))
                   COLLATE DATABASE_DEFAULT
               AND a.VisitID = LTRIM(RTRIM(CONVERT(NVARCHAR(40), p.VisitID)))
                   COLLATE DATABASE_DEFAULT
               AND a.PatientID = LTRIM(RTRIM(CONVERT(NVARCHAR(30), p.PatientID)))
                   COLLATE DATABASE_DEFAULT
        ),
        RankedEmrProblems AS
        (
            SELECT
                normalized.*,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        normalized.SourceID,
                        normalized.PatientID,
                        normalized.PlanUserID,
                        normalized.VisitID,
                        normalized.DocumentID,
                        normalized.ProblemID
                    ORDER BY
                        normalized.ProblemRowUpdateDateTime DESC,
                        normalized.DocumentRowUpdateDateTime DESC,
                        normalized.ProblemDictionaryRowUpdateDateTime DESC,
                        normalized.AccountRowUpdateDateTime DESC
                ) AS rn
            FROM NormalizedEmrProblems AS normalized
        )
        SELECT
            SourceID,
            PatientID,
            PlanUserID,
            VisitID,
            DocumentID,
            ProblemID,
            ProblemRowUpdateDateTime,
            DocumentType,
            DocumentName,
            DocumentStatus,
            DocumentPlanMode,
            DocumentDateTime,
            DocumentCreatedDateTime,
            DocumentLastSaveDateTime,
            DocumentCreatedByUserID,
            DocumentLastSaveUserID,
            DocumentRowUpdateDateTime,
            ProblemDictionaryName,
            ProblemDictionarySource,
            ProblemDictionaryRowUpdateDateTime,
            ServiceDateTime,
            AdmitDateTime,
            ArrivalDateTime,
            FacilityID,
            LocationID,
            ServiceInpatientID,
            ServiceOutpatientID,
            AccountRowUpdateDateTime
        INTO #EmrProblemBase
        FROM RankedEmrProblems
        WHERE rn = 1
          AND
          (
                @ApplyDateWindow = 0
             OR
                (
                    COALESCE
                    (
                        DocumentDateTime,
                        DocumentCreatedDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        ProblemRowUpdateDateTime
                    ) >= @WindowStart
                    AND COALESCE
                    (
                        DocumentDateTime,
                        DocumentCreatedDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        ProblemRowUpdateDateTime
                    ) < @WindowEndPlus1
                )
             OR
                (
                    @IncludeUndated = 1
                    AND COALESCE
                    (
                        DocumentDateTime,
                        DocumentCreatedDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        ProblemRowUpdateDateTime
                    ) IS NULL
                )
          );

        CREATE UNIQUE CLUSTERED INDEX IX_EmrProblemBase_Key
            ON #EmrProblemBase
            (
                SourceID,
                PatientID,
                PlanUserID,
                VisitID,
                DocumentID,
                ProblemID
            );

        IF OBJECT_ID('tempdb..#EmrProblemLabel') IS NOT NULL DROP TABLE #EmrProblemLabel;
        SELECT
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID,
            STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'')
                ) COLLATE DATABASE_DEFAULT,
                NCHAR(13) + NCHAR(10)
            ) WITHIN GROUP (ORDER BY t.TextSeqID, t.TextID) AS ProblemLabelText,
            SUM
            (
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'') IS NOT NULL
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END
            ) AS TextLineCount,
            MAX(t.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #EmrProblemLabel
        FROM #EmrProblemBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPatPlan_Problems_ProblemLabel] AS t
            ON LTRIM(RTRIM(CONVERT(NVARCHAR(3), t.SourceID))) COLLATE DATABASE_DEFAULT = b.SourceID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(30), t.PatientID))) COLLATE DATABASE_DEFAULT = b.PatientID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(25), t.User_UnvUserID))) COLLATE DATABASE_DEFAULT = b.PlanUserID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.VisitID))) COLLATE DATABASE_DEFAULT = b.VisitID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.Document_EmrClinDocID))) COLLATE DATABASE_DEFAULT = b.DocumentID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(48), t.Problem_MisPatProblemID))) COLLATE DATABASE_DEFAULT = b.ProblemID
        GROUP BY
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID;

        CREATE UNIQUE CLUSTERED INDEX IX_EmrProblemLabel_Key
            ON #EmrProblemLabel
            (SourceID, PatientID, PlanUserID, VisitID, DocumentID, ProblemID);

        IF OBJECT_ID('tempdb..#EmrPlanText') IS NOT NULL DROP TABLE #EmrPlanText;
        SELECT
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID,
            STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'')
                ) COLLATE DATABASE_DEFAULT,
                NCHAR(13) + NCHAR(10)
            ) WITHIN GROUP (ORDER BY t.TextSeqID, t.TextID) AS PlanNarrativeText,
            SUM
            (
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'') IS NOT NULL
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END
            ) AS TextLineCount,
            MAX(t.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #EmrPlanText
        FROM #EmrProblemBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPatPlan_Problems_ProblemPlanText] AS t
            ON LTRIM(RTRIM(CONVERT(NVARCHAR(3), t.SourceID))) COLLATE DATABASE_DEFAULT = b.SourceID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(30), t.PatientID))) COLLATE DATABASE_DEFAULT = b.PatientID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(25), t.User_UnvUserID))) COLLATE DATABASE_DEFAULT = b.PlanUserID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.VisitID))) COLLATE DATABASE_DEFAULT = b.VisitID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.Document_EmrClinDocID))) COLLATE DATABASE_DEFAULT = b.DocumentID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(48), t.Problem_MisPatProblemID))) COLLATE DATABASE_DEFAULT = b.ProblemID
        GROUP BY
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID;

        CREATE UNIQUE CLUSTERED INDEX IX_EmrPlanText_Key
            ON #EmrPlanText
            (SourceID, PatientID, PlanUserID, VisitID, DocumentID, ProblemID);

        IF OBJECT_ID('tempdb..#EmrMedicationText') IS NOT NULL DROP TABLE #EmrMedicationText;
        SELECT
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID,
            STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'')
                ) COLLATE DATABASE_DEFAULT,
                NCHAR(13) + NCHAR(10)
            ) WITHIN GROUP (ORDER BY t.TextSeqID, t.TextID) AS PlannedMedicationText,
            SUM
            (
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'') IS NOT NULL
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END
            ) AS TextLineCount,
            MAX(t.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #EmrMedicationText
        FROM #EmrProblemBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPatPlan_Problems_ProblemMedsText] AS t
            ON LTRIM(RTRIM(CONVERT(NVARCHAR(3), t.SourceID))) COLLATE DATABASE_DEFAULT = b.SourceID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(30), t.PatientID))) COLLATE DATABASE_DEFAULT = b.PatientID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(25), t.User_UnvUserID))) COLLATE DATABASE_DEFAULT = b.PlanUserID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.VisitID))) COLLATE DATABASE_DEFAULT = b.VisitID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.Document_EmrClinDocID))) COLLATE DATABASE_DEFAULT = b.DocumentID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(48), t.Problem_MisPatProblemID))) COLLATE DATABASE_DEFAULT = b.ProblemID
        GROUP BY
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID;

        CREATE UNIQUE CLUSTERED INDEX IX_EmrMedicationText_Key
            ON #EmrMedicationText
            (SourceID, PatientID, PlanUserID, VisitID, DocumentID, ProblemID);

        IF OBJECT_ID('tempdb..#EmrOrderText') IS NOT NULL DROP TABLE #EmrOrderText;
        SELECT
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID,
            STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'')
                ) COLLATE DATABASE_DEFAULT,
                NCHAR(13) + NCHAR(10)
            ) WITHIN GROUP (ORDER BY t.TextSeqID, t.TextID) AS PlannedOrderText,
            SUM
            (
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'') IS NOT NULL
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END
            ) AS TextLineCount,
            MAX(t.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #EmrOrderText
        FROM #EmrProblemBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPatPlan_Problems_ProblemOrdersText] AS t
            ON LTRIM(RTRIM(CONVERT(NVARCHAR(3), t.SourceID))) COLLATE DATABASE_DEFAULT = b.SourceID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(30), t.PatientID))) COLLATE DATABASE_DEFAULT = b.PatientID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(25), t.User_UnvUserID))) COLLATE DATABASE_DEFAULT = b.PlanUserID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.VisitID))) COLLATE DATABASE_DEFAULT = b.VisitID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(40), t.Document_EmrClinDocID))) COLLATE DATABASE_DEFAULT = b.DocumentID
           AND LTRIM(RTRIM(CONVERT(NVARCHAR(48), t.Problem_MisPatProblemID))) COLLATE DATABASE_DEFAULT = b.ProblemID
        GROUP BY
            b.SourceID,
            b.PatientID,
            b.PlanUserID,
            b.VisitID,
            b.DocumentID,
            b.ProblemID;

        CREATE UNIQUE CLUSTERED INDEX IX_EmrOrderText_Key
            ON #EmrOrderText
            (SourceID, PatientID, PlanUserID, VisitID, DocumentID, ProblemID);

        INSERT INTO #TreatmentPlanStage
        (
            PatientID,
            VisitID,
            VisitLinkType,
            SourceID,
            TreatmentPlanSourceType,
            TreatmentPlanID,
            SourcePlanID,
            SourcePlanDictionaryID,
            SourceDocumentID,
            SourceProblemID,
            FirstCycleID,
            PlanName,
            PlanType,
            PlanStatus,
            ProblemLabelText,
            ProblemDictionaryName,
            ProblemDictionarySource,
            DiagnosisID,
            DiagnosisName,
            IndicationID,
            IndicationName,
            ClinicID,
            ClinicName,
            DocumentType,
            DocumentName,
            DocumentStatus,
            DocumentPlanMode,
            PlanAuthorUserID,
            PlanCompletedByUserID,
            PlanStoppedByUserID,
            ClinicalDateTime,
            ClinicalDateSource,
            PlanCreatedDateTime,
            PlanStartDateTime,
            PlanEndDateTime,
            PlanInitializedDateTime,
            PlanCompletedDateTime,
            PlanStoppedDateTime,
            FirstPlannedActivityDateTime,
            LastPlannedActivityDateTime,
            FirstActualActivityDateTime,
            LastActualActivityDateTime,
            LastPlanActivityDateTime,
            FacilityID,
            LocationID,
            ServiceInpatientID,
            ServiceOutpatientID,
            ConfidentialFlag,
            KeyIndicator,
            PlanLength,
            PlanLengthOfStay,
            PlanLevelType,
            PlanWeightValue,
            PlanWeightAlternateUnit,
            PlanWeightDateTime,
            BsaMethod,
            PlanItemCount,
            PlannedCycleCount,
            CycleCount,
            OrderCount,
            PlanActivityCount,
            PlanTextLineCount,
            MedicationTextLineCount,
            OrderTextLineCount,
            PlanNarrativeText,
            PlannedMedicationText,
            PlannedOrderText,
            ProtocolText,
            PlanTextSource,
            ClinicalPlausibilityFlag,
            ClinicalPlausibilityIssue,
            SourceRowUpdateDateTime,
            ExtractedFrom,
            ExtractedOn
        )
        SELECT
            b.PatientID,
            b.VisitID,
            N'DOCUMENT_ENCOUNTER',
            b.SourceID,
            N'EMR_PROBLEM_PLAN',
            CONCAT
            (
                N'EMR|', b.SourceID, N'|', b.PatientID, N'|', b.VisitID,
                N'|', b.DocumentID, N'|', b.ProblemID, N'|', b.PlanUserID
            ),
            NULL,
            NULL,
            b.DocumentID,
            b.ProblemID,
            NULL,
            LEFT
            (
                COALESCE
                (
                    lbl.ProblemLabelText COLLATE DATABASE_DEFAULT,
                    b.ProblemDictionaryName COLLATE DATABASE_DEFAULT,
                    b.DocumentName COLLATE DATABASE_DEFAULT
                ),
                500
            ),
            N'PROBLEM_ORIENTED_PLAN',
            NULL,
            lbl.ProblemLabelText,
            b.ProblemDictionaryName,
            b.ProblemDictionarySource,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            b.DocumentType,
            b.DocumentName,
            b.DocumentStatus,
            b.DocumentPlanMode,
            COALESCE(b.PlanUserID, b.DocumentCreatedByUserID),
            NULL,
            NULL,
            clinical.ClinicalDateTime,
            CASE
                WHEN b.DocumentDateTime IS NOT NULL THEN N'EmrClinDoc_Main.DateTime'
                WHEN b.DocumentCreatedDateTime IS NOT NULL THEN N'EmrClinDoc_Main.CreatedDateTime'
                WHEN b.ServiceDateTime IS NOT NULL THEN N'RegAcct_Main.ServiceDateTime'
                WHEN b.AdmitDateTime IS NOT NULL THEN N'RegAcct_Main.AdmitDateTime'
                WHEN b.ProblemRowUpdateDateTime IS NOT NULL THEN N'EmrPatPlan_Problems.RowUpdateDateTime'
                ELSE N'UNRESOLVED'
            END,
            b.DocumentCreatedDateTime,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            b.FacilityID,
            b.LocationID,
            b.ServiceInpatientID,
            b.ServiceOutpatientID,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            planText.TextLineCount,
            meds.TextLineCount,
            ords.TextLineCount,
            planText.PlanNarrativeText,
            meds.PlannedMedicationText,
            ords.PlannedOrderText,
            NULL,
            N'PATIENT_SPECIFIC_PROBLEM_PLAN',
            CASE
                WHEN clinical.ClinicalDateTime IS NULL THEN 'REVIEW'
                WHEN b.DocumentDateTime IS NULL
                 AND b.DocumentCreatedDateTime IS NULL
                 AND b.ServiceDateTime IS NULL
                 AND b.AdmitDateTime IS NULL
                    THEN 'REVIEW'
                ELSE 'PASS'
            END,
            CASE
                WHEN clinical.ClinicalDateTime IS NULL
                    THEN N'No clinically meaningful date could be resolved.'
                WHEN b.DocumentDateTime IS NULL
                 AND b.DocumentCreatedDateTime IS NULL
                 AND b.ServiceDateTime IS NULL
                 AND b.AdmitDateTime IS NULL
                    THEN N'Clinical date falls back to source row update time; review before final certification.'
                ELSE NULL
            END,
            updates.MaxRowUpdateDateTime,
            N'EmrPatPlan_Problems + ProblemLabel + ProblemPlanText + ProblemMedsText + ProblemOrdersText + EmrClinDoc_Main + MisPatProblem_Main',
            @ExtractedOn
        FROM #EmrProblemBase AS b
        LEFT JOIN #EmrProblemLabel AS lbl
            ON lbl.SourceID = b.SourceID
           AND lbl.PatientID = b.PatientID
           AND lbl.PlanUserID = b.PlanUserID
           AND lbl.VisitID = b.VisitID
           AND lbl.DocumentID = b.DocumentID
           AND lbl.ProblemID = b.ProblemID
        LEFT JOIN #EmrPlanText AS planText
            ON planText.SourceID = b.SourceID
           AND planText.PatientID = b.PatientID
           AND planText.PlanUserID = b.PlanUserID
           AND planText.VisitID = b.VisitID
           AND planText.DocumentID = b.DocumentID
           AND planText.ProblemID = b.ProblemID
        LEFT JOIN #EmrMedicationText AS meds
            ON meds.SourceID = b.SourceID
           AND meds.PatientID = b.PatientID
           AND meds.PlanUserID = b.PlanUserID
           AND meds.VisitID = b.VisitID
           AND meds.DocumentID = b.DocumentID
           AND meds.ProblemID = b.ProblemID
        LEFT JOIN #EmrOrderText AS ords
            ON ords.SourceID = b.SourceID
           AND ords.PatientID = b.PatientID
           AND ords.PlanUserID = b.PlanUserID
           AND ords.VisitID = b.VisitID
           AND ords.DocumentID = b.DocumentID
           AND ords.ProblemID = b.ProblemID
        CROSS APPLY
        (
            SELECT COALESCE
            (
                b.DocumentDateTime,
                b.DocumentCreatedDateTime,
                b.ServiceDateTime,
                b.AdmitDateTime,
                b.ProblemRowUpdateDateTime
            ) AS ClinicalDateTime
        ) AS clinical
        CROSS APPLY
        (
            SELECT MAX(v.UpdateDateTime) AS MaxRowUpdateDateTime
            FROM
            (
                VALUES
                    (b.ProblemRowUpdateDateTime),
                    (b.DocumentRowUpdateDateTime),
                    (b.ProblemDictionaryRowUpdateDateTime),
                    (b.AccountRowUpdateDateTime),
                    (lbl.MaxRowUpdateDateTime),
                    (planText.MaxRowUpdateDateTime),
                    (meds.MaxRowUpdateDateTime),
                    (ords.MaxRowUpdateDateTime)
            ) AS v(UpdateDateTime)
        ) AS updates
        WHERE
            COALESCE(planText.TextLineCount, 0)
          + COALESCE(meds.TextLineCount, 0)
          + COALESCE(ords.TextLineCount, 0) > 0
          AND
          (
                @ApplyDateWindow = 0
             OR
                (
                    clinical.ClinicalDateTime >= @WindowStart
                    AND clinical.ClinicalDateTime < @WindowEndPlus1
                )
             OR
                (@IncludeUndated = 1 AND clinical.ClinicalDateTime IS NULL)
          );

        /*==============================================================
          4. Clinical-document problem-instance plans

          This source is retained separately because its overlap with EmrPatPlan_*
          has not yet been clinically and textually adjudicated.
        ==============================================================*/

        IF OBJECT_ID('tempdb..#DocumentProblemPlanBase') IS NOT NULL DROP TABLE #DocumentProblemPlanBase;

        ;WITH RankedDocumentProblemPlans AS
        (
            SELECT
                CONVERT(NVARCHAR(10), p.SourceID) COLLATE DATABASE_DEFAULT AS SourceID,
                CONVERT(NVARCHAR(50), p.EmrClinDocID) COLLATE DATABASE_DEFAULT AS DocumentID,
                CONVERT(NVARCHAR(200), p.ProblemInstanceUrnID) COLLATE DATABASE_DEFAULT AS ProblemInstanceID,
                CONVERT(NVARCHAR(50), p.ProblemPlanUser_UnvUserID) COLLATE DATABASE_DEFAULT AS PlanUserID,
                p.RowUpdateDateTime AS PlanRowUpdateDateTime,

                CONVERT(NVARCHAR(50), d.RegistrationAccount_RegAcctID) COLLATE DATABASE_DEFAULT AS VisitID,
                CONVERT(NVARCHAR(100), d.DocumentType) COLLATE DATABASE_DEFAULT AS DocumentType,
                CONVERT(NVARCHAR(255), d.DocumentName) COLLATE DATABASE_DEFAULT AS DocumentName,
                CONVERT(NVARCHAR(100), d.ZoldStatus) COLLATE DATABASE_DEFAULT AS DocumentStatus,
                CONVERT(NVARCHAR(100), d.DocumentPlanMode) COLLATE DATABASE_DEFAULT AS DocumentPlanMode,
                d.DateTime AS DocumentDateTime,
                d.CreatedDateTime AS DocumentCreatedDateTime,
                CONVERT(NVARCHAR(255), d.CreatedBy_UnvUserID) COLLATE DATABASE_DEFAULT AS DocumentCreatedByUserID,
                d.RowUpdateDateTime AS DocumentRowUpdateDateTime,

                a.PatientID,
                a.ServiceDateTime,
                a.AdmitDateTime,
                a.ArrivalDateTime,
                a.FacilityID,
                a.LocationID,
                a.ServiceInpatientID,
                a.ServiceOutpatientID,
                a.RowUpdateDateTime AS AccountRowUpdateDateTime,

                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        p.SourceID,
                        p.EmrClinDocID,
                        p.ProblemInstanceUrnID,
                        p.ProblemPlanUser_UnvUserID
                    ORDER BY p.RowUpdateDateTime DESC, d.RowUpdateDateTime DESC
                ) AS rn

            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrClinDoc_ProbInstPlans] AS p
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrClinDoc_Main] AS d
                ON d.SourceID = p.SourceID
               AND d.EmrClinDocID = p.EmrClinDocID
            INNER JOIN #RegAcctCohort AS a
                ON a.SourceID = CONVERT(NVARCHAR(50), d.SourceID) COLLATE DATABASE_DEFAULT
               AND a.VisitID = CONVERT(NVARCHAR(50), d.RegistrationAccount_RegAcctID) COLLATE DATABASE_DEFAULT
        )
        SELECT
            SourceID,
            DocumentID,
            ProblemInstanceID,
            PlanUserID,
            PlanRowUpdateDateTime,
            VisitID,
            DocumentType,
            DocumentName,
            DocumentStatus,
            DocumentPlanMode,
            DocumentDateTime,
            DocumentCreatedDateTime,
            DocumentCreatedByUserID,
            DocumentRowUpdateDateTime,
            PatientID,
            ServiceDateTime,
            AdmitDateTime,
            ArrivalDateTime,
            FacilityID,
            LocationID,
            ServiceInpatientID,
            ServiceOutpatientID,
            AccountRowUpdateDateTime
        INTO #DocumentProblemPlanBase
        FROM RankedDocumentProblemPlans
        WHERE rn = 1
          AND
          (
                @ApplyDateWindow = 0
             OR
                (
                    COALESCE
                    (
                        DocumentDateTime,
                        DocumentCreatedDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        PlanRowUpdateDateTime
                    ) >= @WindowStart
                    AND COALESCE
                    (
                        DocumentDateTime,
                        DocumentCreatedDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        PlanRowUpdateDateTime
                    ) < @WindowEndPlus1
                )
             OR
                (
                    @IncludeUndated = 1
                    AND COALESCE
                    (
                        DocumentDateTime,
                        DocumentCreatedDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        PlanRowUpdateDateTime
                    ) IS NULL
                )
          );

        CREATE UNIQUE CLUSTERED INDEX IX_DocumentProblemPlanBase_Key
            ON #DocumentProblemPlanBase (SourceID, DocumentID, ProblemInstanceID, PlanUserID);

        IF OBJECT_ID('tempdb..#DocumentProblemPlanText') IS NOT NULL DROP TABLE #DocumentProblemPlanText;

        SELECT
            b.SourceID,
            b.DocumentID,
            b.ProblemInstanceID,
            b.PlanUserID,
            STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'')
                ) COLLATE DATABASE_DEFAULT,
                NCHAR(13) + NCHAR(10)
            ) WITHIN GROUP (ORDER BY t.TextSeqID, t.TextID) AS PlanNarrativeText,
            SUM
            (
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'') IS NOT NULL
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END
            ) AS TextLineCount,
            MAX(t.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #DocumentProblemPlanText
        FROM #DocumentProblemPlanBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrClinDoc_ProbInstPlans_ProblemPlanText] AS t
            ON CONVERT(NVARCHAR(10), t.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(50), t.EmrClinDocID) COLLATE DATABASE_DEFAULT = b.DocumentID
           AND CONVERT(NVARCHAR(200), t.ProblemInstanceUrnID) COLLATE DATABASE_DEFAULT = b.ProblemInstanceID
           AND CONVERT(NVARCHAR(50), t.ProblemPlanUser_UnvUserID) COLLATE DATABASE_DEFAULT = b.PlanUserID
        GROUP BY
            b.SourceID,
            b.DocumentID,
            b.ProblemInstanceID,
            b.PlanUserID;

        CREATE UNIQUE CLUSTERED INDEX IX_DocumentProblemPlanText_Key
            ON #DocumentProblemPlanText (SourceID, DocumentID, ProblemInstanceID, PlanUserID);

        INSERT INTO #TreatmentPlanStage
        (
            PatientID, VisitID, VisitLinkType, SourceID, TreatmentPlanSourceType,
            TreatmentPlanID, SourcePlanID, SourcePlanDictionaryID, SourceDocumentID,
            SourceProblemID, FirstCycleID, PlanName, PlanType, PlanStatus,
            ProblemLabelText, ProblemDictionaryName, ProblemDictionarySource,
            DiagnosisID, DiagnosisName, IndicationID, IndicationName, ClinicID,
            ClinicName, DocumentType, DocumentName, DocumentStatus, DocumentPlanMode,
            PlanAuthorUserID, PlanCompletedByUserID, PlanStoppedByUserID,
            ClinicalDateTime, ClinicalDateSource, PlanCreatedDateTime, PlanStartDateTime,
            PlanEndDateTime, PlanInitializedDateTime, PlanCompletedDateTime,
            PlanStoppedDateTime, FirstPlannedActivityDateTime,
            LastPlannedActivityDateTime, FirstActualActivityDateTime,
            LastActualActivityDateTime, LastPlanActivityDateTime, FacilityID,
            LocationID, ServiceInpatientID, ServiceOutpatientID, ConfidentialFlag,
            KeyIndicator, PlanLength, PlanLengthOfStay, PlanLevelType, PlanWeightValue,
            PlanWeightAlternateUnit, PlanWeightDateTime, BsaMethod, PlanItemCount,
            PlannedCycleCount, CycleCount, OrderCount, PlanActivityCount,
            PlanTextLineCount, MedicationTextLineCount, OrderTextLineCount,
            PlanNarrativeText, PlannedMedicationText, PlannedOrderText, ProtocolText,
            PlanTextSource, ClinicalPlausibilityFlag, ClinicalPlausibilityIssue,
            SourceRowUpdateDateTime, ExtractedFrom, ExtractedOn
        )
        SELECT
            b.PatientID,
            b.VisitID,
            N'DOCUMENT_ENCOUNTER',
            b.SourceID,
            N'EMR_DOCUMENT_PROBLEM_INSTANCE_PLAN',
            CONCAT
            (
                N'EMRDOC|', b.SourceID, N'|', b.DocumentID,
                N'|', b.ProblemInstanceID, N'|', b.PlanUserID
            ),
            NULL,
            NULL,
            b.DocumentID,
            b.ProblemInstanceID,
            NULL,
            b.DocumentName,
            N'DOCUMENT_PROBLEM_INSTANCE_PLAN',
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            b.DocumentType,
            b.DocumentName,
            b.DocumentStatus,
            b.DocumentPlanMode,
            COALESCE(b.PlanUserID, b.DocumentCreatedByUserID),
            NULL,
            NULL,
            clinical.ClinicalDateTime,
            CASE
                WHEN b.DocumentDateTime IS NOT NULL THEN N'EmrClinDoc_Main.DateTime'
                WHEN b.DocumentCreatedDateTime IS NOT NULL THEN N'EmrClinDoc_Main.CreatedDateTime'
                WHEN b.ServiceDateTime IS NOT NULL THEN N'RegAcct_Main.ServiceDateTime'
                WHEN b.AdmitDateTime IS NOT NULL THEN N'RegAcct_Main.AdmitDateTime'
                WHEN b.PlanRowUpdateDateTime IS NOT NULL THEN N'EmrClinDoc_ProbInstPlans.RowUpdateDateTime'
                ELSE N'UNRESOLVED'
            END,
            b.DocumentCreatedDateTime,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            b.FacilityID,
            b.LocationID,
            b.ServiceInpatientID,
            b.ServiceOutpatientID,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            txt.TextLineCount,
            NULL,
            NULL,
            txt.PlanNarrativeText,
            NULL,
            NULL,
            NULL,
            N'PATIENT_SPECIFIC_DOCUMENT_PLAN',
            'REVIEW',
            CASE
                WHEN clinical.ClinicalDateTime IS NULL
                    THEN N'No clinically meaningful date could be resolved. Potential overlap with EmrPatPlan_* also requires review.'
                WHEN b.DocumentDateTime IS NULL
                 AND b.DocumentCreatedDateTime IS NULL
                 AND b.ServiceDateTime IS NULL
                 AND b.AdmitDateTime IS NULL
                    THEN N'Clinical date falls back to source row update time. Potential overlap with EmrPatPlan_* also requires review.'
                ELSE N'Potential overlap with EmrPatPlan_* requires duplicate-content review before final certification.'
            END,
            updates.MaxRowUpdateDateTime,
            N'EmrClinDoc_ProbInstPlans + EmrClinDoc_ProbInstPlans_ProblemPlanText + EmrClinDoc_Main + RegAcct_Main',
            @ExtractedOn
        FROM #DocumentProblemPlanBase AS b
        INNER JOIN #DocumentProblemPlanText AS txt
            ON txt.SourceID = b.SourceID
           AND txt.DocumentID = b.DocumentID
           AND txt.ProblemInstanceID = b.ProblemInstanceID
           AND txt.PlanUserID = b.PlanUserID
        CROSS APPLY
        (
            SELECT COALESCE
            (
                b.DocumentDateTime,
                b.DocumentCreatedDateTime,
                b.ServiceDateTime,
                b.AdmitDateTime,
                b.PlanRowUpdateDateTime
            ) AS ClinicalDateTime
        ) AS clinical
        CROSS APPLY
        (
            SELECT MAX(v.UpdateDateTime) AS MaxRowUpdateDateTime
            FROM
            (
                VALUES
                    (b.PlanRowUpdateDateTime),
                    (b.DocumentRowUpdateDateTime),
                    (b.AccountRowUpdateDateTime),
                    (txt.MaxRowUpdateDateTime)
            ) AS v(UpdateDateTime)
        ) AS updates
        WHERE txt.TextLineCount > 0
          AND
          (
                @ApplyDateWindow = 0
             OR
                (
                    clinical.ClinicalDateTime >= @WindowStart
                    AND clinical.ClinicalDateTime < @WindowEndPlus1
                )
             OR
                (@IncludeUndated = 1 AND clinical.ClinicalDateTime IS NULL)
          );

        /*==============================================================
          5. Patient Care System care plans

          Grain:
            SourceID + VisitID + PlanUrnID
        ==============================================================*/

        IF OBJECT_ID('tempdb..#PcsPlanBase') IS NOT NULL DROP TABLE #PcsPlanBase;

        ;WITH RankedPcsPlans AS
        (
            SELECT
                CONVERT(NVARCHAR(10), p.SourceID) COLLATE DATABASE_DEFAULT AS SourceID,
                CONVERT(NVARCHAR(50), p.VisitID) COLLATE DATABASE_DEFAULT AS VisitID,
                CONVERT(NVARCHAR(100), p.PlanUrnID) COLLATE DATABASE_DEFAULT AS PlanUrnID,
                p.RowUpdateDateTime AS PlanRowUpdateDateTime,
                CONVERT(NVARCHAR(50), p.Plan_PcsPlanID) COLLATE DATABASE_DEFAULT AS PlanDictionaryID,
                CONVERT(NVARCHAR(150), p.PlanType) COLLATE DATABASE_DEFAULT AS SourcePlanType,
                CONVERT(NVARCHAR(100), p.PlanStatus) COLLATE DATABASE_DEFAULT AS PlanStatus,
                p.PlanLength,
                p.PlanLengthOfStay,
                p.PlanStartDateTime,
                CONVERT(NVARCHAR(10), p.PlanConfidential) COLLATE DATABASE_DEFAULT AS PlanConfidential,
                p.PlanInitializeDateTime,
                CONVERT(NVARCHAR(255), p.PlanInitializeUser_UnvUserID) COLLATE DATABASE_DEFAULT AS PlanInitializeUserID,
                p.PlanCompleteDateTime,
                CONVERT(NVARCHAR(255), p.PlanCompleteUser_UnvUserID) COLLATE DATABASE_DEFAULT AS PlanCompleteUserID,
                p.PlanStopDateTime,
                CONVERT(NVARCHAR(255), p.PlanStopUser_UnvUserID) COLLATE DATABASE_DEFAULT AS PlanStopUserID,
                CONVERT(NVARCHAR(10), p.PlanKeyIndicator) COLLATE DATABASE_DEFAULT AS PlanKeyIndicator,
                CONVERT(NVARCHAR(50), p.PlanLevelType) COLLATE DATABASE_DEFAULT AS PlanLevelType,
                CONVERT(NVARCHAR(500), p.PlanName) COLLATE DATABASE_DEFAULT AS SourcePlanName,

                a.PatientID,
                a.ServiceDateTime,
                a.AdmitDateTime,
                a.ArrivalDateTime,
                a.FacilityID,
                a.LocationID,
                a.ServiceInpatientID,
                a.ServiceOutpatientID,
                a.RowUpdateDateTime AS AccountRowUpdateDateTime,

                CONVERT(NVARCHAR(500), d.Name) COLLATE DATABASE_DEFAULT AS DictionaryPlanName,
                CONVERT(NVARCHAR(150), d.Type) COLLATE DATABASE_DEFAULT AS DictionaryPlanType,
                CONVERT(NVARCHAR(20), d.Active) COLLATE DATABASE_DEFAULT AS DictionaryActive,
                CONVERT(NVARCHAR(10), d.Confidential) COLLATE DATABASE_DEFAULT AS DictionaryConfidential,
                d.RowUpdateDateTime AS DictionaryRowUpdateDateTime,

                ROW_NUMBER() OVER
                (
                    PARTITION BY p.SourceID, p.VisitID, p.PlanUrnID
                    ORDER BY p.RowUpdateDateTime DESC, d.RowUpdateDateTime DESC
                ) AS rn

            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[PcsAcct_Plans] AS p
            INNER JOIN #RegAcctCohort AS a
                ON a.SourceID = CONVERT(NVARCHAR(10), p.SourceID) COLLATE DATABASE_DEFAULT
               AND a.VisitID = CONVERT(NVARCHAR(50), p.VisitID) COLLATE DATABASE_DEFAULT
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[PcsPlan_Main] AS d
                ON d.SourceID = p.SourceID
               AND CONVERT(NVARCHAR(30), d.PcsPlanID) COLLATE DATABASE_DEFAULT =
                   CONVERT(NVARCHAR(30), p.Plan_PcsPlanID) COLLATE DATABASE_DEFAULT
        )
        SELECT
            SourceID,
            VisitID,
            PlanUrnID,
            PlanRowUpdateDateTime,
            PlanDictionaryID,
            SourcePlanType,
            PlanStatus,
            PlanLength,
            PlanLengthOfStay,
            PlanStartDateTime,
            PlanConfidential,
            PlanInitializeDateTime,
            PlanInitializeUserID,
            PlanCompleteDateTime,
            PlanCompleteUserID,
            PlanStopDateTime,
            PlanStopUserID,
            PlanKeyIndicator,
            PlanLevelType,
            SourcePlanName,
            PatientID,
            ServiceDateTime,
            AdmitDateTime,
            ArrivalDateTime,
            FacilityID,
            LocationID,
            ServiceInpatientID,
            ServiceOutpatientID,
            AccountRowUpdateDateTime,
            DictionaryPlanName,
            DictionaryPlanType,
            DictionaryActive,
            DictionaryConfidential,
            DictionaryRowUpdateDateTime
        INTO #PcsPlanBase
        FROM RankedPcsPlans
        WHERE rn = 1
          AND
          (
                @ApplyDateWindow = 0
             OR
                (
                    COALESCE
                    (
                        PlanStartDateTime,
                        PlanInitializeDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        PlanRowUpdateDateTime
                    ) >= @WindowStart
                    AND COALESCE
                    (
                        PlanStartDateTime,
                        PlanInitializeDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        PlanRowUpdateDateTime
                    ) < @WindowEndPlus1
                )
             OR
                (
                    @IncludeUndated = 1
                    AND COALESCE
                    (
                        PlanStartDateTime,
                        PlanInitializeDateTime,
                        ServiceDateTime,
                        AdmitDateTime,
                        PlanRowUpdateDateTime
                    ) IS NULL
                )
          );

        CREATE UNIQUE CLUSTERED INDEX IX_PcsPlanBase_Key
            ON #PcsPlanBase (SourceID, VisitID, PlanUrnID);

        IF OBJECT_ID('tempdb..#PcsPlanItemSummary') IS NOT NULL DROP TABLE #PcsPlanItemSummary;
        SELECT
            b.SourceID,
            b.VisitID,
            b.PlanUrnID,
            COUNT_BIG(*) AS PlanItemCount,
            MAX(i.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #PcsPlanItemSummary
        FROM #PcsPlanBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[PcsAcct_PlanItems] AS i
            ON CONVERT(NVARCHAR(50), i.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(50), i.VisitID) COLLATE DATABASE_DEFAULT = b.VisitID
           AND CONVERT(NVARCHAR(100), i.PlanUrnID) COLLATE DATABASE_DEFAULT = b.PlanUrnID
        GROUP BY b.SourceID, b.VisitID, b.PlanUrnID;

        CREATE UNIQUE CLUSTERED INDEX IX_PcsPlanItemSummary_Key
            ON #PcsPlanItemSummary (SourceID, VisitID, PlanUrnID);

        IF OBJECT_ID('tempdb..#PcsPlanActivitySummary') IS NOT NULL DROP TABLE #PcsPlanActivitySummary;
        SELECT
            b.SourceID,
            b.VisitID,
            b.PlanUrnID,
            COUNT_BIG(*) AS PlanActivityCount,
            MAX(COALESCE(a.PlanActivityDateTime, a.PlanActivityRecordDateTime)) AS LastPlanActivityDateTime,
            MAX(a.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #PcsPlanActivitySummary
        FROM #PcsPlanBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[PcsAcctAct_PlanActivity] AS a
            ON CONVERT(NVARCHAR(50), a.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(50), a.VisitID) COLLATE DATABASE_DEFAULT = b.VisitID
           AND CONVERT(NVARCHAR(100), a.PlanActivityPlanUrnID) COLLATE DATABASE_DEFAULT = b.PlanUrnID
        GROUP BY b.SourceID, b.VisitID, b.PlanUrnID;

        CREATE UNIQUE CLUSTERED INDEX IX_PcsPlanActivitySummary_Key
            ON #PcsPlanActivitySummary (SourceID, VisitID, PlanUrnID);

        IF OBJECT_ID('tempdb..#PcsPlanText') IS NOT NULL DROP TABLE #PcsPlanText;
        SELECT
            b.SourceID,
            b.VisitID,
            b.PlanUrnID,
            STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'')
                ) COLLATE DATABASE_DEFAULT,
                NCHAR(13) + NCHAR(10)
            ) WITHIN GROUP (ORDER BY t.TextSeqID, t.TextID) AS PlanNarrativeText,
            SUM
            (
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'') IS NOT NULL
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END
            ) AS TextLineCount,
            MAX(t.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #PcsPlanText
        FROM #PcsPlanBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[PcsAcct_PlanText_PlanText] AS t
            ON CONVERT(NVARCHAR(10), t.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(50), t.VisitID) COLLATE DATABASE_DEFAULT = b.VisitID
           AND CONVERT(NVARCHAR(100), t.PlanUrnID) COLLATE DATABASE_DEFAULT = b.PlanUrnID
        GROUP BY b.SourceID, b.VisitID, b.PlanUrnID;

        CREATE UNIQUE CLUSTERED INDEX IX_PcsPlanText_Key
            ON #PcsPlanText (SourceID, VisitID, PlanUrnID);

        INSERT INTO #TreatmentPlanStage
        (
            PatientID, VisitID, VisitLinkType, SourceID, TreatmentPlanSourceType,
            TreatmentPlanID, SourcePlanID, SourcePlanDictionaryID, SourceDocumentID,
            SourceProblemID, FirstCycleID, PlanName, PlanType, PlanStatus,
            ProblemLabelText, ProblemDictionaryName, ProblemDictionarySource,
            DiagnosisID, DiagnosisName, IndicationID, IndicationName, ClinicID,
            ClinicName, DocumentType, DocumentName, DocumentStatus, DocumentPlanMode,
            PlanAuthorUserID, PlanCompletedByUserID, PlanStoppedByUserID,
            ClinicalDateTime, ClinicalDateSource, PlanCreatedDateTime, PlanStartDateTime,
            PlanEndDateTime, PlanInitializedDateTime, PlanCompletedDateTime,
            PlanStoppedDateTime, FirstPlannedActivityDateTime,
            LastPlannedActivityDateTime, FirstActualActivityDateTime,
            LastActualActivityDateTime, LastPlanActivityDateTime, FacilityID,
            LocationID, ServiceInpatientID, ServiceOutpatientID, ConfidentialFlag,
            KeyIndicator, PlanLength, PlanLengthOfStay, PlanLevelType, PlanWeightValue,
            PlanWeightAlternateUnit, PlanWeightDateTime, BsaMethod, PlanItemCount,
            PlannedCycleCount, CycleCount, OrderCount, PlanActivityCount,
            PlanTextLineCount, MedicationTextLineCount, OrderTextLineCount,
            PlanNarrativeText, PlannedMedicationText, PlannedOrderText, ProtocolText,
            PlanTextSource, ClinicalPlausibilityFlag, ClinicalPlausibilityIssue,
            SourceRowUpdateDateTime, ExtractedFrom, ExtractedOn
        )
        SELECT
            b.PatientID,
            b.VisitID,
            N'PLAN_ENCOUNTER',
            b.SourceID,
            N'PCS_CARE_PLAN',
            CONCAT(N'PCS|', b.SourceID, N'|', b.VisitID, N'|', b.PlanUrnID),
            b.PlanUrnID,
            b.PlanDictionaryID,
            NULL,
            NULL,
            NULL,
            COALESCE(b.SourcePlanName, b.DictionaryPlanName),
            COALESCE(b.SourcePlanType, b.DictionaryPlanType, N'CARE_PLAN'),
            b.PlanStatus,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            b.PlanInitializeUserID,
            b.PlanCompleteUserID,
            b.PlanStopUserID,
            clinical.ClinicalDateTime,
            CASE
                WHEN b.PlanStartDateTime IS NOT NULL THEN N'PcsAcct_Plans.PlanStartDateTime'
                WHEN b.PlanInitializeDateTime IS NOT NULL THEN N'PcsAcct_Plans.PlanInitializeDateTime'
                WHEN b.ServiceDateTime IS NOT NULL THEN N'RegAcct_Main.ServiceDateTime'
                WHEN b.AdmitDateTime IS NOT NULL THEN N'RegAcct_Main.AdmitDateTime'
                WHEN b.PlanRowUpdateDateTime IS NOT NULL THEN N'PcsAcct_Plans.RowUpdateDateTime'
                ELSE N'UNRESOLVED'
            END,
            NULL,
            b.PlanStartDateTime,
            COALESCE(b.PlanCompleteDateTime, b.PlanStopDateTime),
            b.PlanInitializeDateTime,
            b.PlanCompleteDateTime,
            b.PlanStopDateTime,
            NULL,
            NULL,
            NULL,
            NULL,
            activity.LastPlanActivityDateTime,
            b.FacilityID,
            b.LocationID,
            b.ServiceInpatientID,
            b.ServiceOutpatientID,
            COALESCE(b.PlanConfidential, b.DictionaryConfidential),
            b.PlanKeyIndicator,
            b.PlanLength,
            b.PlanLengthOfStay,
            b.PlanLevelType,
            NULL,
            NULL,
            NULL,
            NULL,
            items.PlanItemCount,
            NULL,
            NULL,
            NULL,
            activity.PlanActivityCount,
            txt.TextLineCount,
            NULL,
            NULL,
            txt.PlanNarrativeText,
            NULL,
            NULL,
            NULL,
            CASE WHEN txt.PlanNarrativeText IS NOT NULL THEN N'PATIENT_CARE_PLAN_TEXT' ELSE NULL END,
            CASE
                WHEN clinical.ClinicalDateTime IS NULL THEN 'REVIEW'
                WHEN b.PlanStartDateTime IS NOT NULL
                 AND b.PlanCompleteDateTime IS NOT NULL
                 AND b.PlanCompleteDateTime < b.PlanStartDateTime THEN 'REVIEW'
                WHEN b.PlanStartDateTime IS NOT NULL
                 AND b.PlanStopDateTime IS NOT NULL
                 AND b.PlanStopDateTime < b.PlanStartDateTime THEN 'REVIEW'
                WHEN b.PlanStartDateTime IS NULL
                 AND b.PlanInitializeDateTime IS NULL
                 AND b.ServiceDateTime IS NULL
                 AND b.AdmitDateTime IS NULL THEN 'REVIEW'
                ELSE 'PASS'
            END,
            CASE
                WHEN clinical.ClinicalDateTime IS NULL
                    THEN N'No clinically meaningful date could be resolved.'
                WHEN b.PlanStartDateTime IS NOT NULL
                 AND b.PlanCompleteDateTime IS NOT NULL
                 AND b.PlanCompleteDateTime < b.PlanStartDateTime
                    THEN N'Plan completion occurs before plan start.'
                WHEN b.PlanStartDateTime IS NOT NULL
                 AND b.PlanStopDateTime IS NOT NULL
                 AND b.PlanStopDateTime < b.PlanStartDateTime
                    THEN N'Plan stop occurs before plan start.'
                WHEN b.PlanStartDateTime IS NULL
                 AND b.PlanInitializeDateTime IS NULL
                 AND b.ServiceDateTime IS NULL
                 AND b.AdmitDateTime IS NULL
                    THEN N'Clinical date falls back to source row update time; review before final certification.'
                ELSE NULL
            END,
            updates.MaxRowUpdateDateTime,
            N'PcsAcct_Plans + PcsPlan_Main + PcsAcct_PlanItems + PcsAcctAct_PlanActivity + PcsAcct_PlanText_PlanText + RegAcct_Main',
            @ExtractedOn
        FROM #PcsPlanBase AS b
        LEFT JOIN #PcsPlanItemSummary AS items
            ON items.SourceID = b.SourceID
           AND items.VisitID = b.VisitID
           AND items.PlanUrnID = b.PlanUrnID
        LEFT JOIN #PcsPlanActivitySummary AS activity
            ON activity.SourceID = b.SourceID
           AND activity.VisitID = b.VisitID
           AND activity.PlanUrnID = b.PlanUrnID
        LEFT JOIN #PcsPlanText AS txt
            ON txt.SourceID = b.SourceID
           AND txt.VisitID = b.VisitID
           AND txt.PlanUrnID = b.PlanUrnID
        CROSS APPLY
        (
            SELECT COALESCE
            (
                b.PlanStartDateTime,
                b.PlanInitializeDateTime,
                b.ServiceDateTime,
                b.AdmitDateTime,
                b.PlanRowUpdateDateTime
            ) AS ClinicalDateTime
        ) AS clinical
        CROSS APPLY
        (
            SELECT MAX(v.UpdateDateTime) AS MaxRowUpdateDateTime
            FROM
            (
                VALUES
                    (b.PlanRowUpdateDateTime),
                    (b.AccountRowUpdateDateTime),
                    (b.DictionaryRowUpdateDateTime),
                    (items.MaxRowUpdateDateTime),
                    (activity.MaxRowUpdateDateTime),
                    (txt.MaxRowUpdateDateTime)
            ) AS v(UpdateDateTime)
        ) AS updates
        WHERE
          (
                @ApplyDateWindow = 0
             OR
                (
                    clinical.ClinicalDateTime >= @WindowStart
                    AND clinical.ClinicalDateTime < @WindowEndPlus1
                )
             OR
                (@IncludeUndated = 1 AND clinical.ClinicalDateTime IS NULL)
          );

        /*==============================================================
          6. Oncology treatment plans

          Grain:
            SourceID + OncPlanID

          Planned dates come from OncPlan_DateCycles.
          Actual cycle dates come from OncCycle_Main.
          Protocol text comes from the reusable plan dictionary and is explicitly
          labelled as standard protocol text, not patient-authored narrative.
        ==============================================================*/

        IF OBJECT_ID('tempdb..#OncologyPlanBase') IS NOT NULL DROP TABLE #OncologyPlanBase;

        ;WITH RankedOncologyPlans AS
        (
            SELECT
                CONVERT(NVARCHAR(10), p.SourceID) COLLATE DATABASE_DEFAULT AS SourceID,
                CONVERT(NVARCHAR(50), p.OncPlanID) COLLATE DATABASE_DEFAULT AS OncPlanID,
                p.RowUpdateDateTime AS PlanRowUpdateDateTime,
                p.CreateDateTime,
                CONVERT(NVARCHAR(255), p.CreateUser_UnvUserID) COLLATE DATABASE_DEFAULT AS CreateUserID,
                CONVERT(NVARCHAR(50), p.Patient_HimRecID) COLLATE DATABASE_DEFAULT AS PatientID,
                CONVERT(NVARCHAR(255), p.DictionaryPlan_OncPlanDictID) COLLATE DATABASE_DEFAULT AS PlanDictionaryID,
                CONVERT(NVARCHAR(100), p.Diagnosis_OncDxID) COLLATE DATABASE_DEFAULT AS DiagnosisID,
                CONVERT(NVARCHAR(50), p.Indication_OncIndicationID) COLLATE DATABASE_DEFAULT AS IndicationID,
                CONVERT(NVARCHAR(50), p.Clinic_OncClinicID) COLLATE DATABASE_DEFAULT AS ClinicID,
                CONVERT(NVARCHAR(50), p.Weight) COLLATE DATABASE_DEFAULT AS PlanWeightValue,
                CONVERT(NVARCHAR(50), p.WeightAlternateUnit) COLLATE DATABASE_DEFAULT AS PlanWeightAlternateUnit,
                p.WeightDateTime AS PlanWeightDateTime,
                CONVERT(NVARCHAR(100), p.Status) COLLATE DATABASE_DEFAULT AS PlanStatus,

                CONVERT(NVARCHAR(500), d.Name) COLLATE DATABASE_DEFAULT AS DictionaryPlanName,
                CONVERT(NVARCHAR(100), d.Mnemonic) COLLATE DATABASE_DEFAULT AS DictionaryPlanMnemonic,
                CONVERT(NVARCHAR(100), d.BsaMethod) COLLATE DATABASE_DEFAULT AS BsaMethod,
                d.RowUpdateDateTime AS DictionaryRowUpdateDateTime,

                CONVERT(NVARCHAR(500), dx.Name) COLLATE DATABASE_DEFAULT AS DiagnosisName,
                dx.RowUpdateDateTime AS DiagnosisRowUpdateDateTime,
                CONVERT(NVARCHAR(500), ind.Name) COLLATE DATABASE_DEFAULT AS IndicationName,
                ind.RowUpdateDateTime AS IndicationRowUpdateDateTime,
                CONVERT(NVARCHAR(255), clinic.Name) COLLATE DATABASE_DEFAULT AS ClinicName,
                clinic.RowUpdateDateTime AS ClinicRowUpdateDateTime,

                ROW_NUMBER() OVER
                (
                    PARTITION BY p.SourceID, p.OncPlanID
                    ORDER BY p.RowUpdateDateTime DESC, d.RowUpdateDateTime DESC
                ) AS rn

            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[OncPlan_Main] AS p
            INNER JOIN #Cohort AS c
                ON CONVERT(NVARCHAR(50), p.Patient_HimRecID) COLLATE DATABASE_DEFAULT = c.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncPlanDict_Main] AS d
                ON d.SourceID = p.SourceID
               AND CONVERT(NVARCHAR(255), d.OncPlanDictID) COLLATE DATABASE_DEFAULT =
                   CONVERT(NVARCHAR(255), p.DictionaryPlan_OncPlanDictID) COLLATE DATABASE_DEFAULT
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncDx_Main] AS dx
                ON dx.SourceID = p.SourceID
               AND dx.OncDxID = p.Diagnosis_OncDxID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncIndication_Main] AS ind
                ON ind.SourceID = p.SourceID
               AND CONVERT(NVARCHAR(30), ind.OncIndicationID) COLLATE DATABASE_DEFAULT =
                   CONVERT(NVARCHAR(30), p.Indication_OncIndicationID) COLLATE DATABASE_DEFAULT
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncClinic_Main] AS clinic
                ON clinic.SourceID = p.SourceID
               AND CONVERT(NVARCHAR(30), clinic.OncClinicID) COLLATE DATABASE_DEFAULT =
                   CONVERT(NVARCHAR(30), p.Clinic_OncClinicID) COLLATE DATABASE_DEFAULT
        )
        SELECT
            SourceID,
            OncPlanID,
            PlanRowUpdateDateTime,
            CreateDateTime,
            CreateUserID,
            PatientID,
            PlanDictionaryID,
            DiagnosisID,
            IndicationID,
            ClinicID,
            PlanWeightValue,
            PlanWeightAlternateUnit,
            PlanWeightDateTime,
            PlanStatus,
            DictionaryPlanName,
            DictionaryPlanMnemonic,
            BsaMethod,
            DictionaryRowUpdateDateTime,
            DiagnosisName,
            DiagnosisRowUpdateDateTime,
            IndicationName,
            IndicationRowUpdateDateTime,
            ClinicName,
            ClinicRowUpdateDateTime
        INTO #OncologyPlanBase
        FROM RankedOncologyPlans
        WHERE rn = 1;

        CREATE UNIQUE CLUSTERED INDEX IX_OncologyPlanBase_Key
            ON #OncologyPlanBase (SourceID, OncPlanID);

        IF OBJECT_ID('tempdb..#OncologyPlannedDates') IS NOT NULL DROP TABLE #OncologyPlannedDates;
        SELECT
            b.SourceID,
            b.OncPlanID,
            MIN(d.DateID) AS FirstPlannedActivityDateTime,
            MAX(d.DateID) AS LastPlannedActivityDateTime,
            COUNT_BIG(DISTINCT CONVERT(NVARCHAR(50), d.DateCycle_OncCycleID)) AS PlannedCycleCount,
            MAX(d.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #OncologyPlannedDates
        FROM #OncologyPlanBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncPlan_DateCycles] AS d
            ON CONVERT(NVARCHAR(50), d.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(50), d.OncPlanID) COLLATE DATABASE_DEFAULT = b.OncPlanID
        GROUP BY b.SourceID, b.OncPlanID;

        CREATE UNIQUE CLUSTERED INDEX IX_OncologyPlannedDates_Key
            ON #OncologyPlannedDates (SourceID, OncPlanID);

        IF OBJECT_ID('tempdb..#OncologyCycleSummary') IS NOT NULL DROP TABLE #OncologyCycleSummary;
        SELECT
            b.SourceID,
            b.OncPlanID,
            COUNT_BIG(DISTINCT CONVERT(NVARCHAR(50), c.OncCycleID)) AS CycleCount,
            MIN(c.StartDate) AS FirstActualActivityDateTime,
            MAX(c.EndDate) AS LastActualActivityDateTime,
            MAX(c.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #OncologyCycleSummary
        FROM #OncologyPlanBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncCycle_Main] AS c
            ON CONVERT(NVARCHAR(50), c.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(50), c.Plan_OncPlanID) COLLATE DATABASE_DEFAULT = b.OncPlanID
        GROUP BY b.SourceID, b.OncPlanID;

        CREATE UNIQUE CLUSTERED INDEX IX_OncologyCycleSummary_Key
            ON #OncologyCycleSummary (SourceID, OncPlanID);

        IF OBJECT_ID('tempdb..#OncologyFirstCycle') IS NOT NULL DROP TABLE #OncologyFirstCycle;
        ;WITH RankedCycles AS
        (
            SELECT
                b.SourceID,
                b.OncPlanID,
                CONVERT(NVARCHAR(50), c.OncCycleID) COLLATE DATABASE_DEFAULT AS FirstCycleID,
                CONVERT(NVARCHAR(50), c.VisitID) COLLATE DATABASE_DEFAULT AS FirstCycleVisitID,
                c.StartDate,
                c.Number,
                ROW_NUMBER() OVER
                (
                    PARTITION BY b.SourceID, b.OncPlanID
                    ORDER BY
                        CASE WHEN c.StartDate IS NULL THEN 1 ELSE 0 END,
                        c.StartDate,
                        c.Number,
                        c.OncCycleID
                ) AS rn
            FROM #OncologyPlanBase AS b
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncCycle_Main] AS c
                ON CONVERT(NVARCHAR(50), c.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
               AND CONVERT(NVARCHAR(50), c.Plan_OncPlanID) COLLATE DATABASE_DEFAULT = b.OncPlanID
        )
        SELECT SourceID, OncPlanID, FirstCycleID, FirstCycleVisitID
        INTO #OncologyFirstCycle
        FROM RankedCycles
        WHERE rn = 1;

        CREATE UNIQUE CLUSTERED INDEX IX_OncologyFirstCycle_Key
            ON #OncologyFirstCycle (SourceID, OncPlanID);

        IF OBJECT_ID('tempdb..#OncologyOrderSummary') IS NOT NULL DROP TABLE #OncologyOrderSummary;
        SELECT
            b.SourceID,
            b.OncPlanID,
            COUNT_BIG(*) AS OrderCount,
            MAX(COALESCE(o.OrderLastDateTimeUpdated, o.RowUpdateDateTime)) AS MaxOrderDateTime,
            MAX(o.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #OncologyOrderSummary
        FROM #OncologyPlanBase AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncPlan_Orders] AS o
            ON CONVERT(NVARCHAR(50), o.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(50), o.OncPlanID) COLLATE DATABASE_DEFAULT = b.OncPlanID
        GROUP BY b.SourceID, b.OncPlanID;

        CREATE UNIQUE CLUSTERED INDEX IX_OncologyOrderSummary_Key
            ON #OncologyOrderSummary (SourceID, OncPlanID);

        IF OBJECT_ID('tempdb..#OncologyProtocolText') IS NOT NULL DROP TABLE #OncologyProtocolText;
        SELECT
            b.SourceID,
            b.PlanDictionaryID,
            STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'')
                ) COLLATE DATABASE_DEFAULT,
                NCHAR(13) + NCHAR(10)
            ) WITHIN GROUP (ORDER BY t.TextSeqID, t.TextID) AS ProtocolText,
            SUM
            (
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(250), t.TextLine))), N'') IS NOT NULL
                        THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
                END
            ) AS TextLineCount,
            MAX(t.RowUpdateDateTime) AS MaxRowUpdateDateTime
        INTO #OncologyProtocolText
        FROM
        (
            SELECT DISTINCT SourceID, PlanDictionaryID
            FROM #OncologyPlanBase
            WHERE PlanDictionaryID IS NOT NULL
        ) AS b
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[OncPlanDict_Protocol_ProtocolMtext] AS t
            ON CONVERT(NVARCHAR(10), t.SourceID) COLLATE DATABASE_DEFAULT = b.SourceID
           AND CONVERT(NVARCHAR(255), t.OncPlanDictID) COLLATE DATABASE_DEFAULT = b.PlanDictionaryID
        GROUP BY b.SourceID, b.PlanDictionaryID;

        CREATE UNIQUE CLUSTERED INDEX IX_OncologyProtocolText_Key
            ON #OncologyProtocolText (SourceID, PlanDictionaryID);

        INSERT INTO #TreatmentPlanStage
        (
            PatientID, VisitID, VisitLinkType, SourceID, TreatmentPlanSourceType,
            TreatmentPlanID, SourcePlanID, SourcePlanDictionaryID, SourceDocumentID,
            SourceProblemID, FirstCycleID, PlanName, PlanType, PlanStatus,
            ProblemLabelText, ProblemDictionaryName, ProblemDictionarySource,
            DiagnosisID, DiagnosisName, IndicationID, IndicationName, ClinicID,
            ClinicName, DocumentType, DocumentName, DocumentStatus, DocumentPlanMode,
            PlanAuthorUserID, PlanCompletedByUserID, PlanStoppedByUserID,
            ClinicalDateTime, ClinicalDateSource, PlanCreatedDateTime, PlanStartDateTime,
            PlanEndDateTime, PlanInitializedDateTime, PlanCompletedDateTime,
            PlanStoppedDateTime, FirstPlannedActivityDateTime,
            LastPlannedActivityDateTime, FirstActualActivityDateTime,
            LastActualActivityDateTime, LastPlanActivityDateTime, FacilityID,
            LocationID, ServiceInpatientID, ServiceOutpatientID, ConfidentialFlag,
            KeyIndicator, PlanLength, PlanLengthOfStay, PlanLevelType, PlanWeightValue,
            PlanWeightAlternateUnit, PlanWeightDateTime, BsaMethod, PlanItemCount,
            PlannedCycleCount, CycleCount, OrderCount, PlanActivityCount,
            PlanTextLineCount, MedicationTextLineCount, OrderTextLineCount,
            PlanNarrativeText, PlannedMedicationText, PlannedOrderText, ProtocolText,
            PlanTextSource, ClinicalPlausibilityFlag, ClinicalPlausibilityIssue,
            SourceRowUpdateDateTime, ExtractedFrom, ExtractedOn
        )
        SELECT
            b.PatientID,
            firstcycle.FirstCycleVisitID,
            CASE WHEN firstcycle.FirstCycleVisitID IS NOT NULL THEN N'FIRST_CYCLE_ENCOUNTER' ELSE NULL END,
            b.SourceID,
            N'ONCOLOGY_TREATMENT_PLAN',
            CONCAT(N'ONC|', b.SourceID, N'|', b.OncPlanID),
            b.OncPlanID,
            b.PlanDictionaryID,
            NULL,
            NULL,
            firstcycle.FirstCycleID,
            COALESCE(b.DictionaryPlanName, b.DictionaryPlanMnemonic, b.OncPlanID),
            N'ONCOLOGY_TREATMENT_PLAN',
            b.PlanStatus,
            NULL,
            NULL,
            NULL,
            b.DiagnosisID,
            b.DiagnosisName,
            b.IndicationID,
            b.IndicationName,
            b.ClinicID,
            b.ClinicName,
            NULL,
            NULL,
            NULL,
            NULL,
            b.CreateUserID,
            NULL,
            NULL,
            clinical.ClinicalDateTime,
            CASE
                WHEN b.CreateDateTime IS NOT NULL THEN N'OncPlan_Main.CreateDateTime'
                WHEN planned.FirstPlannedActivityDateTime IS NOT NULL THEN N'OncPlan_DateCycles.DateID'
                WHEN cycles.FirstActualActivityDateTime IS NOT NULL THEN N'OncCycle_Main.StartDate'
                WHEN b.PlanRowUpdateDateTime IS NOT NULL THEN N'OncPlan_Main.RowUpdateDateTime'
                ELSE N'UNRESOLVED'
            END,
            b.CreateDateTime,
            planned.FirstPlannedActivityDateTime,
            planned.LastPlannedActivityDateTime,
            NULL,
            NULL,
            NULL,
            planned.FirstPlannedActivityDateTime,
            planned.LastPlannedActivityDateTime,
            cycles.FirstActualActivityDateTime,
            cycles.LastActualActivityDateTime,
            NULL,
            acct.FacilityID,
            acct.LocationID,
            acct.ServiceInpatientID,
            acct.ServiceOutpatientID,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            b.PlanWeightValue,
            b.PlanWeightAlternateUnit,
            b.PlanWeightDateTime,
            b.BsaMethod,
            NULL,
            planned.PlannedCycleCount,
            cycles.CycleCount,
            orders.OrderCount,
            NULL,
            protocol.TextLineCount,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
            protocol.ProtocolText,
            CASE WHEN protocol.ProtocolText IS NOT NULL THEN N'STANDARD_DICTIONARY_PROTOCOL_TEXT' ELSE NULL END,
            CASE
                WHEN clinical.ClinicalDateTime IS NULL THEN 'REVIEW'
                WHEN planned.FirstPlannedActivityDateTime IS NOT NULL
                 AND planned.LastPlannedActivityDateTime IS NOT NULL
                 AND planned.LastPlannedActivityDateTime < planned.FirstPlannedActivityDateTime THEN 'REVIEW'
                WHEN cycles.FirstActualActivityDateTime IS NOT NULL
                 AND cycles.LastActualActivityDateTime IS NOT NULL
                 AND cycles.LastActualActivityDateTime < cycles.FirstActualActivityDateTime THEN 'REVIEW'
                WHEN b.CreateDateTime IS NULL
                 AND planned.FirstPlannedActivityDateTime IS NULL
                 AND cycles.FirstActualActivityDateTime IS NULL THEN 'REVIEW'
                ELSE 'PASS'
            END,
            CASE
                WHEN clinical.ClinicalDateTime IS NULL
                    THEN N'No clinically meaningful date could be resolved.'
                WHEN planned.FirstPlannedActivityDateTime IS NOT NULL
                 AND planned.LastPlannedActivityDateTime IS NOT NULL
                 AND planned.LastPlannedActivityDateTime < planned.FirstPlannedActivityDateTime
                    THEN N'Last planned activity occurs before first planned activity.'
                WHEN cycles.FirstActualActivityDateTime IS NOT NULL
                 AND cycles.LastActualActivityDateTime IS NOT NULL
                 AND cycles.LastActualActivityDateTime < cycles.FirstActualActivityDateTime
                    THEN N'Last actual cycle end occurs before first actual cycle start.'
                WHEN b.CreateDateTime IS NULL
                 AND planned.FirstPlannedActivityDateTime IS NULL
                 AND cycles.FirstActualActivityDateTime IS NULL
                    THEN N'Clinical date falls back to source row update time; review before final certification.'
                ELSE NULL
            END,
            updates.MaxRowUpdateDateTime,
            N'OncPlan_Main + OncPlanDict_Main + OncPlanDict_Protocol_ProtocolMtext + OncPlan_DateCycles + OncCycle_Main + OncPlan_Orders + OncDx_Main + OncIndication_Main + OncClinic_Main',
            @ExtractedOn
        FROM #OncologyPlanBase AS b
        LEFT JOIN #OncologyPlannedDates AS planned
            ON planned.SourceID = b.SourceID
           AND planned.OncPlanID = b.OncPlanID
        LEFT JOIN #OncologyCycleSummary AS cycles
            ON cycles.SourceID = b.SourceID
           AND cycles.OncPlanID = b.OncPlanID
        LEFT JOIN #OncologyFirstCycle AS firstcycle
            ON firstcycle.SourceID = b.SourceID
           AND firstcycle.OncPlanID = b.OncPlanID
        LEFT JOIN #OncologyOrderSummary AS orders
            ON orders.SourceID = b.SourceID
           AND orders.OncPlanID = b.OncPlanID
        LEFT JOIN #OncologyProtocolText AS protocol
            ON protocol.SourceID = b.SourceID
           AND protocol.PlanDictionaryID = b.PlanDictionaryID
        LEFT JOIN #RegAcctCohort AS acct
            ON acct.SourceID = b.SourceID
           AND acct.VisitID = firstcycle.FirstCycleVisitID
           AND acct.PatientID = b.PatientID
        CROSS APPLY
        (
            SELECT COALESCE
            (
                b.CreateDateTime,
                planned.FirstPlannedActivityDateTime,
                cycles.FirstActualActivityDateTime,
                b.PlanRowUpdateDateTime
            ) AS ClinicalDateTime
        ) AS clinical
        CROSS APPLY
        (
            SELECT MAX(v.UpdateDateTime) AS MaxRowUpdateDateTime
            FROM
            (
                VALUES
                    (b.PlanRowUpdateDateTime),
                    (b.DictionaryRowUpdateDateTime),
                    (b.DiagnosisRowUpdateDateTime),
                    (b.IndicationRowUpdateDateTime),
                    (b.ClinicRowUpdateDateTime),
                    (planned.MaxRowUpdateDateTime),
                    (cycles.MaxRowUpdateDateTime),
                    (orders.MaxRowUpdateDateTime),
                    (protocol.MaxRowUpdateDateTime),
                    (acct.RowUpdateDateTime)
            ) AS v(UpdateDateTime)
        ) AS updates
        WHERE
          (
                @ApplyDateWindow = 0
             OR
                (
                    clinical.ClinicalDateTime >= @WindowStart
                    AND clinical.ClinicalDateTime < @WindowEndPlus1
                )
             OR
                (@IncludeUndated = 1 AND clinical.ClinicalDateTime IS NULL)
          );

        /*==============================================================
          7. Hard validation before publishing
        ==============================================================*/

        IF EXISTS
        (
            SELECT 1
            FROM #TreatmentPlanStage
            WHERE PatientID IS NULL
               OR SourceID IS NULL
               OR TreatmentPlanSourceType IS NULL
               OR TreatmentPlanID IS NULL
        )
            THROW 53106, 'Treatment Plan stage contains a null mandatory identifier.', 1;

        IF EXISTS
        (
            SELECT TreatmentPlanID
            FROM #TreatmentPlanStage
            GROUP BY TreatmentPlanID
            HAVING COUNT_BIG(*) > 1
        )
            THROW 53107, 'Treatment Plan stage contains duplicate TreatmentPlanID values.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM #TreatmentPlanStage AS s
            LEFT JOIN #Cohort AS c
                ON c.PatientID = s.PatientID COLLATE DATABASE_DEFAULT
            WHERE c.PatientID IS NULL
        )
            THROW 53108, 'Treatment Plan stage contains a patient outside the FCAP cohort.', 1;

        SELECT
            @RecordCount = COUNT_BIG(*),
            @ReviewCount = COALESCE
            (
                SUM
                (
                    CASE
                        WHEN ClinicalPlausibilityFlag = 'REVIEW' THEN CONVERT(BIGINT, 1)
                        ELSE CONVERT(BIGINT, 0)
                    END
                ),
                0
            )
        FROM #TreatmentPlanStage;

        IF @RecordCount = 0
            THROW 53109, 'No Treatment Plan records were produced. Review cohort and source joins before publishing an empty topic.', 1;

        IF @RecordCount > 2147483647
            THROW 53110, 'Treatment Plan row count exceeds the INT capacity of FCAP1A_Cohort_Log.RecordCount.', 1;

        SET @RecordCountForLog = CONVERT(INT, @RecordCount);

        SELECT @EmrProblemPlanCount = COUNT_BIG(*)
        FROM #TreatmentPlanStage
        WHERE TreatmentPlanSourceType = N'EMR_PROBLEM_PLAN';

        SELECT @EmrDocumentPlanCount = COUNT_BIG(*)
        FROM #TreatmentPlanStage
        WHERE TreatmentPlanSourceType = N'EMR_DOCUMENT_PROBLEM_INSTANCE_PLAN';

        SELECT @PcsCarePlanCount = COUNT_BIG(*)
        FROM #TreatmentPlanStage
        WHERE TreatmentPlanSourceType = N'PCS_CARE_PLAN';

        SELECT @OncologyPlanCount = COUNT_BIG(*)
        FROM #TreatmentPlanStage
        WHERE TreatmentPlanSourceType = N'ONCOLOGY_TREATMENT_PLAN';

        /*==============================================================
          8. Publish target atomically after all remote extraction succeeds
        ==============================================================*/

        BEGIN TRANSACTION;

        IF OBJECT_ID('dbo.tbl_FCAP1A_TreatmentPlans_Extended', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_TreatmentPlans_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_TreatmentPlans_Extended
        (
            TreatmentPlanRowID              BIGINT IDENTITY(1,1) NOT NULL
                CONSTRAINT PK_tbl_FCAP1A_TreatmentPlans_Extended PRIMARY KEY,
            PatientID                       NVARCHAR(255)  NOT NULL,
            VisitID                         NVARCHAR(255)  NULL,
            VisitLinkType                   NVARCHAR(60)   NULL,
            SourceID                        NVARCHAR(50)   NOT NULL,
            TreatmentPlanSourceType         NVARCHAR(80)   NOT NULL,
            TreatmentPlanID                 NVARCHAR(450)  NOT NULL,
            SourcePlanID                    NVARCHAR(255)  NULL,
            SourcePlanDictionaryID          NVARCHAR(255)  NULL,
            SourceDocumentID                NVARCHAR(255)  NULL,
            SourceProblemID                 NVARCHAR(255)  NULL,
            FirstCycleID                    NVARCHAR(255)  NULL,
            PlanName                        NVARCHAR(500)  NULL,
            PlanType                        NVARCHAR(150)  NULL,
            PlanStatus                      NVARCHAR(100)  NULL,
            ProblemLabelText                NVARCHAR(MAX)  NULL,
            ProblemDictionaryName           NVARCHAR(500)  NULL,
            ProblemDictionarySource         NVARCHAR(100)  NULL,
            DiagnosisID                     NVARCHAR(255)  NULL,
            DiagnosisName                   NVARCHAR(500)  NULL,
            IndicationID                    NVARCHAR(255)  NULL,
            IndicationName                  NVARCHAR(500)  NULL,
            ClinicID                        NVARCHAR(255)  NULL,
            ClinicName                      NVARCHAR(255)  NULL,
            DocumentType                    NVARCHAR(100)  NULL,
            DocumentName                    NVARCHAR(255)  NULL,
            DocumentStatus                  NVARCHAR(100)  NULL,
            DocumentPlanMode                NVARCHAR(100)  NULL,
            PlanAuthorUserID                NVARCHAR(255)  NULL,
            PlanCompletedByUserID           NVARCHAR(255)  NULL,
            PlanStoppedByUserID             NVARCHAR(255)  NULL,
            ClinicalDateTime                DATETIME       NULL,
            ClinicalDateSource              NVARCHAR(150)  NULL,
            PlanCreatedDateTime             DATETIME       NULL,
            PlanStartDateTime               DATETIME       NULL,
            PlanEndDateTime                 DATETIME       NULL,
            PlanInitializedDateTime         DATETIME       NULL,
            PlanCompletedDateTime           DATETIME       NULL,
            PlanStoppedDateTime             DATETIME       NULL,
            FirstPlannedActivityDateTime    DATETIME       NULL,
            LastPlannedActivityDateTime     DATETIME       NULL,
            FirstActualActivityDateTime     DATETIME       NULL,
            LastActualActivityDateTime      DATETIME       NULL,
            LastPlanActivityDateTime        DATETIME       NULL,
            FacilityID                      NVARCHAR(100)  NULL,
            LocationID                      NVARCHAR(100)  NULL,
            ServiceInpatientID              NVARCHAR(100)  NULL,
            ServiceOutpatientID             NVARCHAR(100)  NULL,
            ConfidentialFlag                NVARCHAR(10)   NULL,
            KeyIndicator                    NVARCHAR(10)   NULL,
            PlanLength                      INT            NULL,
            PlanLengthOfStay                INT            NULL,
            PlanLevelType                   NVARCHAR(50)   NULL,
            PlanWeightValue                 NVARCHAR(50)   NULL,
            PlanWeightAlternateUnit          NVARCHAR(50)   NULL,
            PlanWeightDateTime              DATETIME       NULL,
            BsaMethod                       NVARCHAR(100)  NULL,
            PlanItemCount                   BIGINT         NULL,
            PlannedCycleCount               BIGINT         NULL,
            CycleCount                      BIGINT         NULL,
            OrderCount                      BIGINT         NULL,
            PlanActivityCount               BIGINT         NULL,
            PlanTextLineCount               BIGINT         NULL,
            MedicationTextLineCount         BIGINT         NULL,
            OrderTextLineCount              BIGINT         NULL,
            PlanNarrativeText               NVARCHAR(MAX)  NULL,
            PlannedMedicationText           NVARCHAR(MAX)  NULL,
            PlannedOrderText                NVARCHAR(MAX)  NULL,
            ProtocolText                    NVARCHAR(MAX)  NULL,
            PlanTextSource                  NVARCHAR(100)  NULL,
            ClinicalPlausibilityFlag        VARCHAR(20)    NOT NULL,
            ClinicalPlausibilityIssue       NVARCHAR(1000) NULL,
            SourceRowUpdateDateTime          DATETIME       NULL,
            ExtractedFrom                   NVARCHAR(1000) NOT NULL,
            ExtractedOn                     DATETIME       NOT NULL,
            hashkey                         CHAR(64)       NOT NULL
        );

        INSERT INTO dbo.tbl_FCAP1A_TreatmentPlans_Extended
        (
            PatientID, VisitID, VisitLinkType, SourceID, TreatmentPlanSourceType,
            TreatmentPlanID, SourcePlanID, SourcePlanDictionaryID, SourceDocumentID,
            SourceProblemID, FirstCycleID, PlanName, PlanType, PlanStatus,
            ProblemLabelText, ProblemDictionaryName, ProblemDictionarySource,
            DiagnosisID, DiagnosisName, IndicationID, IndicationName, ClinicID,
            ClinicName, DocumentType, DocumentName, DocumentStatus, DocumentPlanMode,
            PlanAuthorUserID, PlanCompletedByUserID, PlanStoppedByUserID,
            ClinicalDateTime, ClinicalDateSource, PlanCreatedDateTime, PlanStartDateTime,
            PlanEndDateTime, PlanInitializedDateTime, PlanCompletedDateTime,
            PlanStoppedDateTime, FirstPlannedActivityDateTime,
            LastPlannedActivityDateTime, FirstActualActivityDateTime,
            LastActualActivityDateTime, LastPlanActivityDateTime, FacilityID,
            LocationID, ServiceInpatientID, ServiceOutpatientID, ConfidentialFlag,
            KeyIndicator, PlanLength, PlanLengthOfStay, PlanLevelType, PlanWeightValue,
            PlanWeightAlternateUnit, PlanWeightDateTime, BsaMethod, PlanItemCount,
            PlannedCycleCount, CycleCount, OrderCount, PlanActivityCount,
            PlanTextLineCount, MedicationTextLineCount, OrderTextLineCount,
            PlanNarrativeText, PlannedMedicationText, PlannedOrderText, ProtocolText,
            PlanTextSource, ClinicalPlausibilityFlag, ClinicalPlausibilityIssue,
            SourceRowUpdateDateTime, ExtractedFrom, ExtractedOn, hashkey
        )
        SELECT
            PatientID, VisitID, VisitLinkType, SourceID, TreatmentPlanSourceType,
            TreatmentPlanID, SourcePlanID, SourcePlanDictionaryID, SourceDocumentID,
            SourceProblemID, FirstCycleID, PlanName, PlanType, PlanStatus,
            ProblemLabelText, ProblemDictionaryName, ProblemDictionarySource,
            DiagnosisID, DiagnosisName, IndicationID, IndicationName, ClinicID,
            ClinicName, DocumentType, DocumentName, DocumentStatus, DocumentPlanMode,
            PlanAuthorUserID, PlanCompletedByUserID, PlanStoppedByUserID,
            ClinicalDateTime, ClinicalDateSource, PlanCreatedDateTime, PlanStartDateTime,
            PlanEndDateTime, PlanInitializedDateTime, PlanCompletedDateTime,
            PlanStoppedDateTime, FirstPlannedActivityDateTime,
            LastPlannedActivityDateTime, FirstActualActivityDateTime,
            LastActualActivityDateTime, LastPlanActivityDateTime, FacilityID,
            LocationID, ServiceInpatientID, ServiceOutpatientID, ConfidentialFlag,
            KeyIndicator, PlanLength, PlanLengthOfStay, PlanLevelType, PlanWeightValue,
            PlanWeightAlternateUnit, PlanWeightDateTime, BsaMethod, PlanItemCount,
            PlannedCycleCount, CycleCount, OrderCount, PlanActivityCount,
            PlanTextLineCount, MedicationTextLineCount, OrderTextLineCount,
            PlanNarrativeText, PlannedMedicationText, PlannedOrderText, ProtocolText,
            PlanTextSource, ClinicalPlausibilityFlag, ClinicalPlausibilityIssue,
            SourceRowUpdateDateTime, ExtractedFrom, ExtractedOn,
            CONVERT
            (
                CHAR(64),
                HASHBYTES
                (
                    'SHA2_256',
                    CONCAT
                    (
                        PatientID, N'|',
                        TreatmentPlanID, N'|',
                        CONVERT(VARCHAR(33), ClinicalDateTime, 126)
                    )
                ),
                2
            ) AS hashkey
        FROM #TreatmentPlanStage;

        IF EXISTS
        (
            SELECT 1
            FROM dbo.tbl_FCAP1A_TreatmentPlans_Extended
            WHERE LEN(hashkey) <> 64
               OR hashkey COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9A-F]%'
        )
            THROW 53111, 'One or more Treatment Plan hashkey values are not valid 64-character SHA-256 hexadecimal strings.', 1;

        IF EXISTS
        (
            SELECT hashkey
            FROM dbo.tbl_FCAP1A_TreatmentPlans_Extended
            GROUP BY hashkey
            HAVING COUNT_BIG(*) > 1
        )
            THROW 53112, 'Duplicate Treatment Plan hashkey values detected. Review the declared natural grain.', 1;

        CREATE UNIQUE INDEX UX_TreatmentPlans_TreatmentPlanID
            ON dbo.tbl_FCAP1A_TreatmentPlans_Extended (TreatmentPlanID);

        CREATE UNIQUE INDEX UX_TreatmentPlans_hashkey
            ON dbo.tbl_FCAP1A_TreatmentPlans_Extended (hashkey);

        CREATE INDEX IX_TreatmentPlans_PatientClinicalDate
            ON dbo.tbl_FCAP1A_TreatmentPlans_Extended
            (
                PatientID,
                ClinicalDateTime
            )
            INCLUDE
            (
                TreatmentPlanSourceType,
                PlanName,
                PlanStatus,
                VisitID
            );

        CREATE INDEX IX_TreatmentPlans_Visit
            ON dbo.tbl_FCAP1A_TreatmentPlans_Extended
            (
                SourceID,
                VisitID
            )
            INCLUDE
            (
                PatientID,
                TreatmentPlanSourceType,
                ClinicalDateTime
            );

        CREATE INDEX IX_TreatmentPlans_SourceType
            ON dbo.tbl_FCAP1A_TreatmentPlans_Extended
            (
                TreatmentPlanSourceType,
                ClinicalPlausibilityFlag
            )
            INCLUDE
            (
                PatientID,
                ClinicalDateTime,
                PlanName
            );

        COMMIT TRANSACTION;

        /*==============================================================
          9. Log and return compact build profile
        ==============================================================*/

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        SET @Remarks = CONCAT
        (
            N'Preliminary unified Treatment Plan build. ',
            N'LifetimeDefault=', CASE WHEN @ApplyDateWindow = 0 THEN N'Yes' ELSE N'No' END,
            N'; EMRProblemPlans=', @EmrProblemPlanCount,
            N'; EMRDocumentProblemPlans=', @EmrDocumentPlanCount,
            N'; PcsCarePlans=', @PcsCarePlanCount,
            N'; OncologyPlans=', @OncologyPlanCount,
            N'; ReviewFlaggedRows=', @ReviewCount,
            N'; HashAlgorithm=SHA2_256',
            N'; HashInput=PatientID + TreatmentPlanID + ClinicalDateTime',
            N'; HashKeyIncluded=Yes.'
        );

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            'TreatmentPlans_Extended',
            CASE WHEN @ApplyDateWindow = 1 THEN @WindowStart ELSE NULL END,
            CASE WHEN @ApplyDateWindow = 1 THEN @WindowEnd ELSE NULL END,
            @TotalEligible,
            @RecordCountForLog,
            SYSTEM_USER,
            NULL,
            @Remarks
        );

        SELECT
            TreatmentPlanSourceType,
            ClinicalPlausibilityFlag,
            COUNT_BIG(*) AS RecordCount,
            COUNT_BIG(DISTINCT PatientID) AS PatientCount,
            MIN(ClinicalDateTime) AS EarliestClinicalDateTime,
            MAX(ClinicalDateTime) AS LatestClinicalDateTime,
            SUM(CASE WHEN ClinicalDateTime IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UndatedCount,
            SUM(CASE WHEN PlanNarrativeText IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS RowsWithPatientPlanText,
            SUM(CASE WHEN ProtocolText IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS RowsWithDictionaryProtocolText,
            COUNT_BIG(DISTINCT hashkey) AS DistinctHashKeyCount
        FROM dbo.tbl_FCAP1A_TreatmentPlans_Extended
        GROUP BY
            TreatmentPlanSourceType,
            ClinicalPlausibilityFlag
        ORDER BY
            TreatmentPlanSourceType,
            ClinicalPlausibilityFlag;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);
        SET @ErrorMessage = ERROR_MESSAGE();

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            'TreatmentPlans_Extended',
            CASE WHEN @ApplyDateWindow = 1 THEN @WindowStart ELSE NULL END,
            CASE WHEN @ApplyDateWindow = 1 THEN @WindowEnd ELSE NULL END,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @ErrorMessage,
            N'Preliminary Treatment Plan build failed before publication completed.'
        );

        THROW;
    END CATCH;
END;
GO

/*
    Recommended preliminary execution, lifetime longitudinal plans:

    EXEC dbo.usp_Build_FCAP1A_TreatmentPlans_Extended;

    Optional clinical-date window:

    EXEC dbo.usp_Build_FCAP1A_TreatmentPlans_Extended
        @ApplyDateWindow = 1,
        @WindowStart = '2022-11-05',
        @WindowEnd = '2026-06-14',
        @IncludeUndated = 0;
*/
