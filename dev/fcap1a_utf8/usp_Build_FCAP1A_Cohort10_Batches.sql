USE [CDIO_MeditechDB];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_Cohort10_Batches]
    @SeedDefaultConfig BIT = 1,
    @ResetOutput BIT = 1,
    @LongTextThreshold INT = 3000,
    @VeryLongTextThreshold INT = 8000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @RunStart DATETIME = SYSDATETIME(),
        @RunEnd DATETIME,
        @DurationSeconds INT,
        @ErrMsg NVARCHAR(4000),

        @ScanRunID UNIQUEIDENTIFIER = NEWID(),
        @ScanDateTime DATETIME2(0) = SYSDATETIME(),
        @TotalCohortPatients INT,
        @BatchSize INT,
        @RemainderPatients INT,
        @ResolvedConfigRows INT = 0,
        @SelectedConfigRows INT = 0,
        @SelectedFamilyCount INT = 0,
        @FinalRowsInserted INT = 0;

    BEGIN TRY

        /* =====================================================
           0. LOG TABLE GUARD
           ===================================================== */

        IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
        BEGIN
            CREATE TABLE dbo.FCAP1A_Cohort_Log (
                LogID           INT IDENTITY(1,1) PRIMARY KEY,
                RunStart        DATETIME NOT NULL,
                RunEnd          DATETIME NULL,
                DurationSeconds INT NULL,
                RunStatus       VARCHAR(20) NOT NULL,
                DataTopic       NVARCHAR(100) NOT NULL,
                WindowStart     DATE NULL,
                WindowEnd       DATE NULL,
                TotalEligible   INT NULL,
                RecordCount     INT NULL,
                ProcessedBy     NVARCHAR(100) DEFAULT SYSTEM_USER,
                ErrorMessage    NVARCHAR(4000) NULL,
                Remarks         NVARCHAR(4000) NULL
            );
        END;


        /* =====================================================
           1. VALIDATION
           ===================================================== */

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended', 'U') IS NULL
        BEGIN
            THROW 52001, 'dbo.tbl_FCAP1A_Cohort10_Extended does not exist. Build the official 10 percent cohort first.', 1;
        END;

        IF @LongTextThreshold < 1
           OR @VeryLongTextThreshold < 1
           OR @VeryLongTextThreshold < @LongTextThreshold
        BEGIN
            THROW 52002, 'Invalid text thresholds. VeryLongTextThreshold must be greater than or equal to LongTextThreshold.', 1;
        END;

        SELECT @TotalCohortPatients = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended WITH (NOLOCK);

        IF @TotalCohortPatients IS NULL OR @TotalCohortPatients = 0
        BEGIN
            THROW 52003, 'dbo.tbl_FCAP1A_Cohort10_Extended is empty. Cannot create batches.', 1;
        END;

        IF @TotalCohortPatients < 5
        BEGIN
            THROW 52004, 'The cohort has fewer than five patients. Cannot create five batches.', 1;
        END;

        SET @BatchSize = FLOOR(@TotalCohortPatients / 5.0);
        SET @RemainderPatients = @TotalCohortPatients - (@BatchSize * 5);


        /* =====================================================
           2. REQUIRED TABLES
           ===================================================== */

        IF OBJECT_ID('dbo.tbl_FCAP1A_BatchRichnessConfig', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.tbl_FCAP1A_BatchRichnessConfig (
                ConfigID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                SourceFamily NVARCHAR(100) NOT NULL,
                SourceSchema SYSNAME NOT NULL DEFAULT ('dbo'),
                SourceTable SYSNAME NOT NULL,
                TextColumn SYSNAME NOT NULL,
                DataTopic NVARCHAR(150) NOT NULL,
                TextTier CHAR(1) NOT NULL,
                SourcePriority INT NOT NULL,
                IncludeInRichnessScore BIT NOT NULL DEFAULT (1),
                IncludeInPHIRiskScan BIT NOT NULL DEFAULT (1),
                IsSparseHighRisk BIT NOT NULL DEFAULT (0),
                IncludeInScan BIT NOT NULL DEFAULT (1),
                MinTextLength INT NOT NULL DEFAULT (1),
                Notes NVARCHAR(1000) NULL,
                CreatedAt DATETIME2(0) NOT NULL DEFAULT (SYSDATETIME()),
                UpdatedAt DATETIME2(0) NULL,

                CONSTRAINT CK_FCAP1A_BatchRichnessConfig_TextTier
                    CHECK (TextTier IN ('A','B','C')),

                CONSTRAINT UQ_FCAP1A_BatchRichnessConfig
                    UNIQUE (SourceFamily, SourceSchema, SourceTable, TextColumn)
            );
        END;

        IF COL_LENGTH('dbo.tbl_FCAP1A_BatchRichnessConfig', 'IncludeInPHIRiskScan') IS NULL
        BEGIN
            ALTER TABLE dbo.tbl_FCAP1A_BatchRichnessConfig
            ADD IncludeInPHIRiskScan BIT NOT NULL
                CONSTRAINT DF_FCAP1A_BatchRichnessConfig_IncludeInPHIRiskScan DEFAULT (1);
        END;

        IF COL_LENGTH('dbo.tbl_FCAP1A_BatchRichnessConfig', 'MinTextLength') IS NULL
        BEGIN
            ALTER TABLE dbo.tbl_FCAP1A_BatchRichnessConfig
            ADD MinTextLength INT NOT NULL
                CONSTRAINT DF_FCAP1A_BatchRichnessConfig_MinTextLength DEFAULT (1);
        END;

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Batches', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.tbl_FCAP1A_Cohort10_Batches (
                PatientID NVARCHAR(50) NOT NULL PRIMARY KEY,
                MostRecentEncounterDate DATETIME NOT NULL,
                EncounterCount INT NOT NULL,

                Batch INT NOT NULL,
                BatchDescription NVARCHAR(150) NOT NULL,
                IsRemainderPatient BIT NOT NULL,

                RichnessRank INT NOT NULL,
                RichnessScore DECIMAL(38,4) NOT NULL,

                SourceFamiliesPresent INT NOT NULL,
                TierASourceFamiliesPresent INT NOT NULL,
                TierBSourceFamiliesPresent INT NOT NULL,
                TierCSourceFamiliesPresent INT NOT NULL,
                SparseHighRiskFamiliesPresent INT NOT NULL,

                TotalMeaningfulTextRows BIGINT NOT NULL,
                TotalNonEmptyTextValues BIGINT NOT NULL,
                TotalTextLength BIGINT NOT NULL,
                MaxTextLength INT NOT NULL,
                LongTextRows BIGINT NOT NULL,
                VeryLongTextRows BIGINT NOT NULL,

                ClinicalNarrativeFlag BIT NOT NULL,
                PathologyFlag BIT NOT NULL,
                LabCommentFlag BIT NOT NULL,
                ADTTextFlag BIT NOT NULL,
                AllergyTextFlag BIT NOT NULL,
                PPITextFlag BIT NOT NULL,
                OtherTextFlag BIT NOT NULL,

                TotalCohortPatients INT NOT NULL,
                BatchSize INT NOT NULL,

                ScanRunID UNIQUEIDENTIFIER NOT NULL,
                ScanDateTime DATETIME2(0) NOT NULL
            );
        END;


        /* =====================================================
           3. SEED LEAN FCAP-ONLY CONFIG
           ===================================================== */

        IF @SeedDefaultConfig = 1
        BEGIN
            DECLARE @DefaultConfig TABLE (
                SourceFamily NVARCHAR(100) NOT NULL,
                SourceSchema SYSNAME NOT NULL,
                SourceTable SYSNAME NOT NULL,
                TextColumn SYSNAME NOT NULL,
                DataTopic NVARCHAR(150) NOT NULL,
                TextTier CHAR(1) NOT NULL,
                SourcePriority INT NOT NULL,
                IncludeInRichnessScore BIT NOT NULL,
                IncludeInPHIRiskScan BIT NOT NULL,
                IsSparseHighRisk BIT NOT NULL,
                IncludeInScan BIT NOT NULL,
                MinTextLength INT NOT NULL,
                Notes NVARCHAR(1000) NULL
            );

            INSERT INTO @DefaultConfig
            VALUES
                ('ClinicalNarrative', 'dbo', 'tbl_FCAP1A_ClinicalNarrative_Extended', 'NarrativeText', 'Clinical narrative', 'A', 1, 1, 1, 0, 1, 1, 'Master clinical notes/narrative source. Do not use ClinicalNotes tables for scoring.'),

                ('PathologyEHR', 'dbo', 'tbl_FCAP1A_PathologyEHR_Extended', 'PathologyText', 'Pathology EHR', 'A', 1, 1, 1, 1, 1, 1, 'Preferred reconstructed pathology narrative.'),
                ('PathologyReports', 'dbo', 'tbl_FCAP1A_PathologyReports_Extended', 'FindingsText', 'Pathology reports', 'A', 1, 1, 1, 1, 1, 1, 'Pathology report findings text.'),
                ('PathologyReports', 'dbo', 'tbl_FCAP1A_PathologyReports_Extended', 'AddendumText', 'Pathology reports', 'A', 1, 1, 1, 1, 1, 1, 'Pathology report addendum text.'),

                ('LabResultComments', 'dbo', 'tbl_FCAP1A_Labs_ResultComments_Extended', 'TextLine', 'Lab result comments', 'B', 1, 1, 1, 1, 1, 1, 'Lab result comment text.'),
                ('LabSpecimenComments', 'dbo', 'tbl_FCAP1A_Labs_SpecimenComments_Extended', 'TextLine', 'Lab specimen comments', 'B', 1, 1, 1, 1, 1, 1, 'Lab specimen comment text.'),
                ('LabMicrobiologyComments', 'dbo', 'tbl_FCAP1A_Labs_Microbiology_Comments_Extended', 'TextLine', 'Microbiology comments', 'B', 1, 1, 1, 1, 1, 1, 'Microbiology comment text.'),
                ('LabBloodBank', 'dbo', 'tbl_FCAP1A_Labs_BloodBank_Extended', 'SignOutComment', 'Blood bank', 'B', 1, 1, 1, 1, 1, 1, 'Blood bank sign-out comment.'),

                ('ADT', 'dbo', 'tbl_FCAP1A_ADT_Extended', 'ReasonForVisit', 'ADT', 'B', 1, 1, 1, 0, 1, 1, 'Reason for visit.'),
                ('ADT', 'dbo', 'tbl_FCAP1A_ADT_Extended', 'DepartureComment', 'ADT', 'B', 1, 1, 1, 0, 1, 1, 'Departure or discharge comment.'),
                ('Flowsheets', 'dbo', 'tbl_FCAP1A_Flowsheets_Extended', 'ChiefComplaint', 'Flowsheets', 'B', 1, 1, 1, 0, 1, 1, 'Chief complaint text.'),

                ('Allergies', 'dbo', 'tbl_FCAP1A_Allergies_Extended', 'Reaction', 'Allergies', 'B', 1, 1, 1, 0, 1, 1, 'Allergy reaction text.'),
                ('Allergies', 'dbo', 'tbl_FCAP1A_Allergies_Extended', 'AllergyText', 'Allergies', 'B', 1, 1, 1, 0, 1, 1, 'Allergy free text.'),
                ('Allergies', 'dbo', 'tbl_FCAP1A_Allergies_Extended', 'AllergyCommentText', 'Allergies', 'B', 1, 1, 1, 0, 1, 1, 'Allergy comment text.'),

                ('Immunizations', 'dbo', 'tbl_FCAP1A_Immunizations_Extended', 'Reason', 'Immunizations', 'C', 1, 1, 1, 0, 1, 1, 'Immunization reason.'),
                ('Immunizations', 'dbo', 'tbl_FCAP1A_Immunizations_Extended', 'Reaction', 'Immunizations', 'C', 1, 1, 1, 0, 1, 1, 'Immunization reaction text.'),
                ('PatientProvidedInfo', 'dbo', 'tbl_FCAP1A_PatientProvidedInfo_Extended', 'AttributeValue', 'Patient provided info', 'C', 1, 1, 1, 0, 1, 1, 'Patient-provided attribute value.'),
                ('Diagnoses', 'dbo', 'tbl_FCAP1A_Diagnoses_Extended', 'DiagnosisFromTransferService', 'Diagnoses', 'C', 1, 1, 1, 0, 1, 1, 'Free-text diagnosis from transfer service.');

            UPDATE c
            SET
                IncludeInScan = 0,
                IncludeInRichnessScore = 0,
                UpdatedAt = SYSDATETIME(),
                Notes = CONCAT(COALESCE(c.Notes, N''), N' | Disabled by corrected lean FCAP batch procedure.')
            FROM dbo.tbl_FCAP1A_BatchRichnessConfig c
            WHERE NOT EXISTS (
                SELECT 1
                FROM @DefaultConfig d
                WHERE d.SourceFamily = c.SourceFamily
                  AND d.SourceSchema = c.SourceSchema
                  AND d.SourceTable = c.SourceTable
                  AND d.TextColumn = c.TextColumn
            );

            UPDATE c
            SET
                c.DataTopic = d.DataTopic,
                c.TextTier = d.TextTier,
                c.SourcePriority = d.SourcePriority,
                c.IncludeInRichnessScore = d.IncludeInRichnessScore,
                c.IncludeInPHIRiskScan = d.IncludeInPHIRiskScan,
                c.IsSparseHighRisk = d.IsSparseHighRisk,
                c.IncludeInScan = d.IncludeInScan,
                c.MinTextLength = d.MinTextLength,
                c.Notes = d.Notes,
                c.UpdatedAt = SYSDATETIME()
            FROM dbo.tbl_FCAP1A_BatchRichnessConfig c
            INNER JOIN @DefaultConfig d
                ON d.SourceFamily = c.SourceFamily
               AND d.SourceSchema = c.SourceSchema
               AND d.SourceTable = c.SourceTable
               AND d.TextColumn = c.TextColumn;

            INSERT INTO dbo.tbl_FCAP1A_BatchRichnessConfig (
                SourceFamily,
                SourceSchema,
                SourceTable,
                TextColumn,
                DataTopic,
                TextTier,
                SourcePriority,
                IncludeInRichnessScore,
                IncludeInPHIRiskScan,
                IsSparseHighRisk,
                IncludeInScan,
                MinTextLength,
                Notes
            )
            SELECT
                d.SourceFamily,
                d.SourceSchema,
                d.SourceTable,
                d.TextColumn,
                d.DataTopic,
                d.TextTier,
                d.SourcePriority,
                d.IncludeInRichnessScore,
                d.IncludeInPHIRiskScan,
                d.IsSparseHighRisk,
                d.IncludeInScan,
                d.MinTextLength,
                d.Notes
            FROM @DefaultConfig d
            WHERE NOT EXISTS (
                SELECT 1
                FROM dbo.tbl_FCAP1A_BatchRichnessConfig c
                WHERE c.SourceFamily = d.SourceFamily
                  AND c.SourceSchema = d.SourceSchema
                  AND c.SourceTable = d.SourceTable
                  AND c.TextColumn = d.TextColumn
            );
        END;


        /* =====================================================
           4. RESET OUTPUT
           ===================================================== */

        IF @ResetOutput = 1
        BEGIN
            DELETE FROM dbo.tbl_FCAP1A_Cohort10_Batches;
        END;

        IF EXISTS (SELECT 1 FROM dbo.tbl_FCAP1A_Cohort10_Batches)
        BEGIN
            THROW 52005, 'dbo.tbl_FCAP1A_Cohort10_Batches is not empty. Run with @ResetOutput = 1 or clear the table before rerunning.', 1;
        END;


        /* =====================================================
           5. TEMP TABLES
           ===================================================== */

        IF OBJECT_ID('tempdb..#ResolvedConfig') IS NOT NULL DROP TABLE #ResolvedConfig;
        IF OBJECT_ID('tempdb..#SelectedConfig') IS NOT NULL DROP TABLE #SelectedConfig;
        IF OBJECT_ID('tempdb..#SkippedConfig') IS NOT NULL DROP TABLE #SkippedConfig;
        IF OBJECT_ID('tempdb..#ScanGroups') IS NOT NULL DROP TABLE #ScanGroups;
        IF OBJECT_ID('tempdb..#FamilyScan') IS NOT NULL DROP TABLE #FamilyScan;
        IF OBJECT_ID('tempdb..#PatientSummary') IS NOT NULL DROP TABLE #PatientSummary;

        CREATE TABLE #ResolvedConfig (
            SourceFamily NVARCHAR(100) NOT NULL,
            SourceSchema SYSNAME NOT NULL,
            SourceTable SYSNAME NOT NULL,
            TextColumn SYSNAME NOT NULL,
            DataTopic NVARCHAR(150) NOT NULL,
            TextTier CHAR(1) NOT NULL,
            SourcePriority INT NOT NULL,
            IsSparseHighRisk BIT NOT NULL,
            MinTextLength INT NOT NULL
        );

        CREATE TABLE #SkippedConfig (
            SourceFamily NVARCHAR(100) NOT NULL,
            SourceSchema SYSNAME NOT NULL,
            SourceTable SYSNAME NOT NULL,
            TextColumn SYSNAME NOT NULL,
            Reason NVARCHAR(300) NOT NULL
        );

        CREATE TABLE #FamilyScan (
            PatientID NVARCHAR(50) NOT NULL,
            SourceFamily NVARCHAR(100) NOT NULL,
            SourceTable SYSNAME NOT NULL,
            TextTier CHAR(1) NOT NULL,
            IsSparseHighRisk BIT NOT NULL,
            TotalRows BIGINT NOT NULL,
            MeaningfulTextRows BIGINT NOT NULL,
            NonEmptyTextValueCount BIGINT NOT NULL,
            TotalTextLength BIGINT NOT NULL,
            MaxTextLength INT NOT NULL,
            LongTextRows BIGINT NOT NULL,
            VeryLongTextRows BIGINT NOT NULL
        );


        /* =====================================================
           6. RESOLVE ACTIVE CONFIG
           ===================================================== */

        INSERT INTO #ResolvedConfig
        SELECT
            cfg.SourceFamily,
            cfg.SourceSchema,
            cfg.SourceTable,
            cfg.TextColumn,
            cfg.DataTopic,
            cfg.TextTier,
            cfg.SourcePriority,
            cfg.IsSparseHighRisk,
            cfg.MinTextLength
        FROM dbo.tbl_FCAP1A_BatchRichnessConfig cfg
        INNER JOIN sys.schemas s
            ON s.name = cfg.SourceSchema
        INNER JOIN sys.tables t
            ON t.schema_id = s.schema_id
           AND t.name = cfg.SourceTable
        INNER JOIN sys.columns patient_col
            ON patient_col.object_id = t.object_id
           AND patient_col.name = 'PatientID'
        INNER JOIN sys.columns text_col
            ON text_col.object_id = t.object_id
           AND text_col.name = cfg.TextColumn
        WHERE cfg.IncludeInScan = 1
          AND cfg.IncludeInRichnessScore = 1
          AND cfg.SourceSchema = 'dbo'
          AND cfg.SourceTable LIKE 'tbl_FCAP1A[_]%'
          AND cfg.SourceTable NOT IN (
                'tbl_FCAP1A_ClinicalNotes_Extended',
                'tbl_FCAP1A_ClinicalNotes_Extended_Merged'
          );

        INSERT INTO #SkippedConfig
        SELECT
            cfg.SourceFamily,
            cfg.SourceSchema,
            cfg.SourceTable,
            cfg.TextColumn,
            CASE
                WHEN cfg.IncludeInScan = 0 THEN 'Config row disabled.'
                WHEN cfg.IncludeInRichnessScore = 0 THEN 'Not included in richness score.'
                WHEN cfg.SourceSchema <> 'dbo' THEN 'Not dbo schema.'
                WHEN cfg.SourceTable NOT LIKE 'tbl_FCAP1A[_]%' THEN 'Not an FCAP extracted table.'
                WHEN cfg.SourceTable IN ('tbl_FCAP1A_ClinicalNotes_Extended', 'tbl_FCAP1A_ClinicalNotes_Extended_Merged') THEN 'Clinical notes restricted to ClinicalNarrative only.'
                WHEN s.schema_id IS NULL THEN 'Schema not found.'
                WHEN t.object_id IS NULL THEN 'Table not found.'
                WHEN patient_col.object_id IS NULL THEN 'PatientID column not found.'
                WHEN text_col.object_id IS NULL THEN 'Configured text column not found.'
                ELSE 'Unknown skip reason.'
            END AS Reason
        FROM dbo.tbl_FCAP1A_BatchRichnessConfig cfg
        LEFT JOIN sys.schemas s
            ON s.name = cfg.SourceSchema
        LEFT JOIN sys.tables t
            ON t.schema_id = s.schema_id
           AND t.name = cfg.SourceTable
        LEFT JOIN sys.columns patient_col
            ON patient_col.object_id = t.object_id
           AND patient_col.name = 'PatientID'
        LEFT JOIN sys.columns text_col
            ON text_col.object_id = t.object_id
           AND text_col.name = cfg.TextColumn
        WHERE cfg.IncludeInScan = 0
           OR cfg.IncludeInRichnessScore = 0
           OR cfg.SourceSchema <> 'dbo'
           OR cfg.SourceTable NOT LIKE 'tbl_FCAP1A[_]%'
           OR cfg.SourceTable IN (
                'tbl_FCAP1A_ClinicalNotes_Extended',
                'tbl_FCAP1A_ClinicalNotes_Extended_Merged'
           )
           OR s.schema_id IS NULL
           OR t.object_id IS NULL
           OR patient_col.object_id IS NULL
           OR text_col.object_id IS NULL;

        SELECT @ResolvedConfigRows = COUNT(*)
        FROM #ResolvedConfig;


        /* =====================================================
           7. FAMILY SELECTION
           ===================================================== */

        ;WITH FamilyPriority AS (
            SELECT
                SourceFamily,
                MIN(SourcePriority) AS SelectedPriority
            FROM #ResolvedConfig
            GROUP BY SourceFamily
        )
        SELECT r.*
        INTO #SelectedConfig
        FROM #ResolvedConfig r
        INNER JOIN FamilyPriority fp
            ON fp.SourceFamily = r.SourceFamily
           AND fp.SelectedPriority = r.SourcePriority;

        SELECT
            @SelectedConfigRows = COUNT(*),
            @SelectedFamilyCount = COUNT(DISTINCT SourceFamily)
        FROM #SelectedConfig;

        CREATE TABLE #ScanGroups (
            SourceFamily NVARCHAR(100) NOT NULL,
            SourceSchema SYSNAME NOT NULL,
            SourceTable SYSNAME NOT NULL,
            DataTopic NVARCHAR(150) NOT NULL,
            TextTier CHAR(1) NOT NULL,
            SourcePriority INT NOT NULL,
            IsSparseHighRisk BIT NOT NULL,
            MinTextLength INT NOT NULL
        );

        INSERT INTO #ScanGroups
        SELECT
            SourceFamily,
            SourceSchema,
            SourceTable,
            DataTopic,
            MIN(TextTier) AS TextTier,
            SourcePriority,
            CAST(MAX(CAST(IsSparseHighRisk AS INT)) AS BIT) AS IsSparseHighRisk,
            MIN(MinTextLength) AS MinTextLength
        FROM #SelectedConfig
        GROUP BY
            SourceFamily,
            SourceSchema,
            SourceTable,
            DataTopic,
            SourcePriority;


        /* =====================================================
           8. SCAN TEXT SOURCES
           ===================================================== */

        IF EXISTS (SELECT 1 FROM #ScanGroups)
        BEGIN
            DECLARE
                @SourceFamily NVARCHAR(100),
                @SourceSchema SYSNAME,
                @SourceTable SYSNAME,
                @DataTopic NVARCHAR(150),
                @TextTier CHAR(1),
                @SourcePriority INT,
                @IsSparseHighRisk BIT,
                @MinTextLength INT,
                @Predicate NVARCHAR(MAX),
                @ValueCountExpression NVARCHAR(MAX),
                @LengthSumExpression NVARCHAR(MAX),
                @RowMaxLengthExpression NVARCHAR(MAX),
                @Sql NVARCHAR(MAX);

            DECLARE scan_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT
                SourceFamily,
                SourceSchema,
                SourceTable,
                DataTopic,
                TextTier,
                SourcePriority,
                IsSparseHighRisk,
                MinTextLength
            FROM #ScanGroups
            ORDER BY SourceFamily, SourcePriority, SourceTable;

            OPEN scan_cursor;

            FETCH NEXT FROM scan_cursor
            INTO
                @SourceFamily,
                @SourceSchema,
                @SourceTable,
                @DataTopic,
                @TextTier,
                @SourcePriority,
                @IsSparseHighRisk,
                @MinTextLength;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @Predicate = N'';
                SET @ValueCountExpression = N'';
                SET @LengthSumExpression = N'';
                SET @RowMaxLengthExpression = N'';

                SELECT
                    @Predicate =
                        @Predicate +
                        CASE WHEN LEN(@Predicate) > 0 THEN N' OR ' ELSE N'' END +
                        N'(
                            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N'))), N'''') IS NOT NULL
                            AND LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) >= @MinTextLength
                            AND UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) NOT IN
                                (N''NULL'', N''N/A'', N''NA'', N''UNKNOWN'', N''NOT DOCUMENTED'', N''NONE'', N''-'', N''.'')
                        )',

                    @ValueCountExpression =
                        @ValueCountExpression +
                        CASE WHEN LEN(@ValueCountExpression) > 0 THEN N' + ' ELSE N'' END +
                        N'CASE
                            WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N'))), N'''') IS NOT NULL
                             AND LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) >= @MinTextLength
                             AND UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) NOT IN
                                (N''NULL'', N''N/A'', N''NA'', N''UNKNOWN'', N''NOT DOCUMENTED'', N''NONE'', N''-'', N''.'')
                            THEN 1 ELSE 0
                        END',

                    @LengthSumExpression =
                        @LengthSumExpression +
                        CASE WHEN LEN(@LengthSumExpression) > 0 THEN N' + ' ELSE N'' END +
                        N'CASE
                            WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N'))), N'''') IS NOT NULL
                             AND LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) >= @MinTextLength
                             AND UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) NOT IN
                                (N''NULL'', N''N/A'', N''NA'', N''UNKNOWN'', N''NOT DOCUMENTED'', N''NONE'', N''-'', N''.'')
                            THEN LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) ELSE 0
                        END',

                    @RowMaxLengthExpression =
                        @RowMaxLengthExpression +
                        CASE WHEN LEN(@RowMaxLengthExpression) > 0 THEN N',' ELSE N'' END +
                        N'(CASE
                            WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N'))), N'''') IS NOT NULL
                             AND LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) >= @MinTextLength
                             AND UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) NOT IN
                                (N''NULL'', N''N/A'', N''NA'', N''UNKNOWN'', N''NOT DOCUMENTED'', N''NONE'', N''-'', N''.'')
                            THEN LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(TextColumn) + N')))) ELSE 0
                        END)'
                FROM #SelectedConfig
                WHERE SourceFamily = @SourceFamily
                  AND SourceSchema = @SourceSchema
                  AND SourceTable = @SourceTable
                  AND SourcePriority = @SourcePriority
                ORDER BY TextColumn;

                SET @RowMaxLengthExpression =
                    N'(SELECT MAX(v.TextLen) FROM (VALUES ' + @RowMaxLengthExpression + N') AS v(TextLen))';

                SET @Sql = N'
                    INSERT INTO #FamilyScan
                    SELECT
                        x.PatientID,
                        @SourceFamily AS SourceFamily,
                        @SourceTable AS SourceTable,
                        @TextTier AS TextTier,
                        @IsSparseHighRisk AS IsSparseHighRisk,
                        COUNT_BIG(*) AS TotalRows,
                        SUM(CAST(x.MeaningfulRowFlag AS BIGINT)) AS MeaningfulTextRows,
                        SUM(CAST(x.NonEmptyTextValueCount AS BIGINT)) AS NonEmptyTextValueCount,
                        SUM(CAST(x.RowTextLength AS BIGINT)) AS TotalTextLength,
                        MAX(x.RowMaxTextLength) AS MaxTextLength,
                        SUM(CASE WHEN x.RowMaxTextLength >= @LongTextThreshold THEN CAST(1 AS BIGINT) ELSE CAST(0 AS BIGINT) END) AS LongTextRows,
                        SUM(CASE WHEN x.RowMaxTextLength >= @VeryLongTextThreshold THEN CAST(1 AS BIGINT) ELSE CAST(0 AS BIGINT) END) AS VeryLongTextRows
                    FROM (
                        SELECT
                            CAST(t.PatientID AS NVARCHAR(50)) AS PatientID,
                            CASE WHEN ' + @Predicate + N' THEN 1 ELSE 0 END AS MeaningfulRowFlag,
                            (' + @ValueCountExpression + N') AS NonEmptyTextValueCount,
                            (' + @LengthSumExpression + N') AS RowTextLength,
                            ' + @RowMaxLengthExpression + N' AS RowMaxTextLength
                        FROM ' + QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable) + N' AS t WITH (NOLOCK)
                        INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended AS c WITH (NOLOCK)
                            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                               CAST(t.PatientID AS NVARCHAR(50)) COLLATE SQL_Latin1_General_CP1_CI_AS
                        WHERE t.PatientID IS NOT NULL
                    ) AS x
                    GROUP BY x.PatientID
                    HAVING SUM(CAST(x.MeaningfulRowFlag AS BIGINT)) > 0;
                ';

                EXEC sys.sp_executesql
                    @Sql,
                    N'@SourceFamily NVARCHAR(100),
                      @SourceTable SYSNAME,
                      @TextTier CHAR(1),
                      @IsSparseHighRisk BIT,
                      @MinTextLength INT,
                      @LongTextThreshold INT,
                      @VeryLongTextThreshold INT',
                    @SourceFamily = @SourceFamily,
                    @SourceTable = @SourceTable,
                    @TextTier = @TextTier,
                    @IsSparseHighRisk = @IsSparseHighRisk,
                    @MinTextLength = @MinTextLength,
                    @LongTextThreshold = @LongTextThreshold,
                    @VeryLongTextThreshold = @VeryLongTextThreshold;

                FETCH NEXT FROM scan_cursor
                INTO
                    @SourceFamily,
                    @SourceSchema,
                    @SourceTable,
                    @DataTopic,
                    @TextTier,
                    @SourcePriority,
                    @IsSparseHighRisk,
                    @MinTextLength;
            END;

            CLOSE scan_cursor;
            DEALLOCATE scan_cursor;
        END;


        /* =====================================================
           9. AGGREGATE FULL COHORT
           ===================================================== */

        SELECT
            c.PatientID,
            c.MostRecentEncounterDate,
            c.EncounterCount,

            COUNT(DISTINCT fs.SourceFamily) AS SourceFamiliesPresent,
            COUNT(DISTINCT CASE WHEN fs.TextTier = 'A' THEN fs.SourceFamily END) AS TierASourceFamiliesPresent,
            COUNT(DISTINCT CASE WHEN fs.TextTier = 'B' THEN fs.SourceFamily END) AS TierBSourceFamiliesPresent,
            COUNT(DISTINCT CASE WHEN fs.TextTier = 'C' THEN fs.SourceFamily END) AS TierCSourceFamiliesPresent,
            COUNT(DISTINCT CASE WHEN fs.IsSparseHighRisk = 1 THEN fs.SourceFamily END) AS SparseHighRiskFamiliesPresent,

            COALESCE(SUM(fs.MeaningfulTextRows), 0) AS TotalMeaningfulTextRows,
            COALESCE(SUM(fs.NonEmptyTextValueCount), 0) AS TotalNonEmptyTextValues,
            COALESCE(SUM(fs.TotalTextLength), 0) AS TotalTextLength,
            COALESCE(MAX(fs.MaxTextLength), 0) AS MaxTextLength,
            COALESCE(SUM(fs.LongTextRows), 0) AS LongTextRows,
            COALESCE(SUM(fs.VeryLongTextRows), 0) AS VeryLongTextRows,

            CAST(MAX(CASE WHEN fs.SourceFamily = 'ClinicalNarrative' THEN 1 ELSE 0 END) AS BIT) AS ClinicalNarrativeFlag,
            CAST(MAX(CASE WHEN fs.SourceFamily IN ('PathologyEHR', 'PathologyReports') THEN 1 ELSE 0 END) AS BIT) AS PathologyFlag,
            CAST(MAX(CASE WHEN fs.SourceFamily IN ('LabResultComments', 'LabSpecimenComments', 'LabMicrobiologyComments', 'LabBloodBank') THEN 1 ELSE 0 END) AS BIT) AS LabCommentFlag,
            CAST(MAX(CASE WHEN fs.SourceFamily = 'ADT' THEN 1 ELSE 0 END) AS BIT) AS ADTTextFlag,
            CAST(MAX(CASE WHEN fs.SourceFamily = 'Allergies' THEN 1 ELSE 0 END) AS BIT) AS AllergyTextFlag,
            CAST(MAX(CASE WHEN fs.SourceFamily = 'PatientProvidedInfo' THEN 1 ELSE 0 END) AS BIT) AS PPITextFlag,
            CAST(MAX(CASE WHEN fs.SourceFamily IS NOT NULL
                            AND fs.SourceFamily NOT IN (
                                'ClinicalNarrative',
                                'PathologyEHR',
                                'PathologyReports',
                                'LabResultComments',
                                'LabSpecimenComments',
                                'LabMicrobiologyComments',
                                'LabBloodBank',
                                'ADT',
                                'Allergies',
                                'PatientProvidedInfo'
                            )
                          THEN 1 ELSE 0 END) AS BIT) AS OtherTextFlag
        INTO #PatientSummary
        FROM dbo.tbl_FCAP1A_Cohort10_Extended c WITH (NOLOCK)
        LEFT JOIN #FamilyScan fs
            ON fs.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        GROUP BY
            c.PatientID,
            c.MostRecentEncounterDate,
            c.EncounterCount;


        /* =====================================================
           10. SCORE, RANK, BATCH
           ===================================================== */

        ;WITH Scored AS (
            SELECT
                *,
                CAST(
                    (CAST(SourceFamiliesPresent AS DECIMAL(38,4)) * 1000000000.0) +
                    (CAST(TierASourceFamiliesPresent AS DECIMAL(38,4)) * 100000000.0) +
                    (CAST(SparseHighRiskFamiliesPresent AS DECIMAL(38,4)) * 10000000.0) +
                    (CAST(VeryLongTextRows AS DECIMAL(38,4)) * 10000.0) +
                    (CAST(LongTextRows AS DECIMAL(38,4)) * 1000.0) +
                    (LOG10(CAST(TotalMeaningfulTextRows AS FLOAT) + 1.0) * 100.0) +
                    (LOG10(CAST(TotalNonEmptyTextValues AS FLOAT) + 1.0) * 10.0) +
                    (LOG10(CAST(TotalTextLength AS FLOAT) + 1.0))
                    AS DECIMAL(38,4)
                ) AS RichnessScore
            FROM #PatientSummary
        ),
        Ranked AS (
            SELECT
                *,
                ROW_NUMBER() OVER (
                    ORDER BY
                        SourceFamiliesPresent DESC,
                        TierASourceFamiliesPresent DESC,
                        SparseHighRiskFamiliesPresent DESC,
                        VeryLongTextRows DESC,
                        LongTextRows DESC,
                        TotalMeaningfulTextRows DESC,
                        TotalNonEmptyTextValues DESC,
                        TotalTextLength DESC,
                        MaxTextLength DESC,
                        PatientID ASC
                ) AS RichnessRank
            FROM Scored
        ),
        Batched AS (
            SELECT
                *,
                CASE
                    WHEN RichnessRank <= @BatchSize * 1 THEN 1
                    WHEN RichnessRank <= @BatchSize * 2 THEN 2
                    WHEN RichnessRank <= @BatchSize * 3 THEN 3
                    WHEN RichnessRank <= @BatchSize * 4 THEN 4
                    WHEN RichnessRank <= @BatchSize * 5 THEN 5
                    ELSE 0
                END AS Batch
            FROM Ranked
        )
        INSERT INTO dbo.tbl_FCAP1A_Cohort10_Batches (
            PatientID,
            MostRecentEncounterDate,
            EncounterCount,
            Batch,
            BatchDescription,
            IsRemainderPatient,
            RichnessRank,
            RichnessScore,
            SourceFamiliesPresent,
            TierASourceFamiliesPresent,
            TierBSourceFamiliesPresent,
            TierCSourceFamiliesPresent,
            SparseHighRiskFamiliesPresent,
            TotalMeaningfulTextRows,
            TotalNonEmptyTextValues,
            TotalTextLength,
            MaxTextLength,
            LongTextRows,
            VeryLongTextRows,
            ClinicalNarrativeFlag,
            PathologyFlag,
            LabCommentFlag,
            ADTTextFlag,
            AllergyTextFlag,
            PPITextFlag,
            OtherTextFlag,
            TotalCohortPatients,
            BatchSize,
            ScanRunID,
            ScanDateTime
        )
        SELECT
            PatientID,
            MostRecentEncounterDate,
            EncounterCount,
            Batch,
            CASE Batch
                WHEN 0 THEN 'Batch 0 - remainder / holdout'
                WHEN 1 THEN 'Batch 1 - richest unstructured patients'
                WHEN 2 THEN 'Batch 2 - rich unstructured patients'
                WHEN 3 THEN 'Batch 3 - moderate unstructured richness'
                WHEN 4 THEN 'Batch 4 - thin unstructured records'
                WHEN 5 THEN 'Batch 5 - thinnest official capped batch'
            END AS BatchDescription,
            CASE WHEN Batch = 0 THEN 1 ELSE 0 END AS IsRemainderPatient,
            RichnessRank,
            RichnessScore,
            SourceFamiliesPresent,
            TierASourceFamiliesPresent,
            TierBSourceFamiliesPresent,
            TierCSourceFamiliesPresent,
            SparseHighRiskFamiliesPresent,
            TotalMeaningfulTextRows,
            TotalNonEmptyTextValues,
            TotalTextLength,
            MaxTextLength,
            LongTextRows,
            VeryLongTextRows,
            ClinicalNarrativeFlag,
            PathologyFlag,
            LabCommentFlag,
            ADTTextFlag,
            AllergyTextFlag,
            PPITextFlag,
            OtherTextFlag,
            @TotalCohortPatients,
            @BatchSize,
            @ScanRunID,
            @ScanDateTime
        FROM Batched;

        SET @FinalRowsInserted = @@ROWCOUNT;


        /* =====================================================
           11. SUCCESS LOG
           ===================================================== */

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
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
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            'Cohort10_Batches',
            NULL,
            NULL,
            @TotalCohortPatients,
            @FinalRowsInserted,
            SYSTEM_USER,
            NULL,
            CONCAT(
                'FCAP 1A cohort 10 batch allocation completed. ',
                'BatchSize=', @BatchSize,
                '; RemainderPatients=', @RemainderPatients,
                '; ResolvedConfigRows=', @ResolvedConfigRows,
                '; SelectedConfigRows=', @SelectedConfigRows,
                '; SelectedFamilyCount=', @SelectedFamilyCount,
                '; ScanRunID=', CONVERT(NVARCHAR(50), @ScanRunID)
            )
        );


        /* =====================================================
           12. RESULT SETS
           ===================================================== */

        SELECT
            @ScanRunID AS ScanRunID,
            @ScanDateTime AS ScanDateTime,
            @TotalCohortPatients AS TotalCohortPatients,
            @BatchSize AS BatchSize,
            @RemainderPatients AS RemainderPatients,
            @ResolvedConfigRows AS ResolvedConfigRows,
            @SelectedConfigRows AS SelectedConfigRows,
            @SelectedFamilyCount AS SelectedFamilyCount,
            @FinalRowsInserted AS FinalRowsInserted;

        SELECT
            Batch,
            BatchDescription,
            COUNT(*) AS PatientCount,
            MIN(RichnessRank) AS MinRichnessRank,
            MAX(RichnessRank) AS MaxRichnessRank,
            CAST(AVG(CAST(RichnessScore AS DECIMAL(38,8))) AS DECIMAL(38,4)) AS AvgRichnessScore,
            CAST(AVG(CAST(SourceFamiliesPresent AS DECIMAL(18,4))) AS DECIMAL(18,4)) AS AvgSourceFamiliesPresent,
            CAST(AVG(CAST(TierASourceFamiliesPresent AS DECIMAL(18,4))) AS DECIMAL(18,4)) AS AvgTierAFamilies,
            CAST(AVG(CAST(TotalMeaningfulTextRows AS DECIMAL(18,4))) AS DECIMAL(18,4)) AS AvgMeaningfulTextRows,
            CAST(AVG(CAST(TotalTextLength AS DECIMAL(18,4))) AS DECIMAL(18,4)) AS AvgTotalTextLength
        FROM dbo.tbl_FCAP1A_Cohort10_Batches
        GROUP BY Batch, BatchDescription
        ORDER BY Batch;

        SELECT
            SourceFamily,
            SourceSchema,
            SourceTable,
            TextColumn,
            DataTopic,
            TextTier,
            SourcePriority,
            IsSparseHighRisk,
            MinTextLength
        FROM #SelectedConfig
        ORDER BY SourceFamily, SourcePriority, SourceTable, TextColumn;

        SELECT
            SourceFamily,
            SourceSchema,
            SourceTable,
            TextColumn,
            Reason
        FROM #SkippedConfig
        ORDER BY Reason, SourceFamily, SourceTable, TextColumn;

    END TRY

    BEGIN CATCH

        IF CURSOR_STATUS('local', 'scan_cursor') >= -1
        BEGIN
            IF CURSOR_STATUS('local', 'scan_cursor') > -1
            BEGIN
                CLOSE scan_cursor;
            END;

            DEALLOCATE scan_cursor;
        END;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);
        SET @ErrMsg = ERROR_MESSAGE();

        IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NOT NULL
        BEGIN
            INSERT INTO dbo.FCAP1A_Cohort_Log (
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
            VALUES (
                @RunStart,
                @RunEnd,
                @DurationSeconds,
                'FAILED',
                'Cohort10_Batches',
                NULL,
                NULL,
                @TotalCohortPatients,
                NULLIF(@FinalRowsInserted, 0),
                SYSTEM_USER,
                @ErrMsg,
                CONCAT(
                    'FCAP 1A cohort 10 batch allocation failed. ',
                    'ResolvedConfigRows=', COALESCE(CONVERT(NVARCHAR(20), @ResolvedConfigRows), 'NULL'),
                    '; SelectedConfigRows=', COALESCE(CONVERT(NVARCHAR(20), @SelectedConfigRows), 'NULL'),
                    '; SelectedFamilyCount=', COALESCE(CONVERT(NVARCHAR(20), @SelectedFamilyCount), 'NULL'),
                    '; ScanRunID=', CONVERT(NVARCHAR(50), @ScanRunID)
                )
            );
        END;

        THROW;

    END CATCH;
END;
GO