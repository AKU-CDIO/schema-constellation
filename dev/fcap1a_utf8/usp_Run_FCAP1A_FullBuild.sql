USE [CDIO_MeditechDB];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Run_FCAP1A_FullBuild]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @RunStart DATETIME = SYSDATETIME(),
        @RunEnd DATETIME,
        @DurationSeconds INT,
        @Step NVARCHAR(300) = N'Not started',
        @TotalEligible INT = NULL,
        @FinalBatchRows INT = NULL,
        @ErrMsg NVARCHAR(4000),
        @ThrowMsg NVARCHAR(2048);

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

    BEGIN TRY

        /* =====================================================
           1. COHORT
           ===================================================== */

        SET @Step = N'Build official FCAP 1A 10 percent cohort';
        RAISERROR(N'1. Building official FCAP 1A 10 percent cohort...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Cohort10_Extended;


        /* =====================================================
           2. CORE ADMINISTRATIVE / PATIENT ANCHORS
           ===================================================== */

        SET @Step = N'Build demographics';
        RAISERROR(N'2.1 Building demographics...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Demographics_Extended;

        SET @Step = N'Build ADT';
        RAISERROR(N'2.2 Building ADT...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_ADT_Extended;

        SET @Step = N'Build encounters';
        RAISERROR(N'2.3 Building encounters...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Encounters_Extended;

        SET @Step = N'Build patient referrals';
        RAISERROR(N'2.4 Building patient referrals...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_PatientReferrals_Extended;


        /* =====================================================
           3. CLINICAL DOMAINS
           ===================================================== */

        SET @Step = N'Build allergies';
        RAISERROR(N'3.1 Building allergies...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Allergies_Extended;

        SET @Step = N'Build diagnoses';
        RAISERROR(N'3.2 Building diagnoses...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Diagnoses_Extended;

        SET @Step = N'Build procedures';
        RAISERROR(N'3.3 Building procedures...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Procedures_Extended;

        SET @Step = N'Build immunizations';
        RAISERROR(N'3.4 Building immunizations...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Immunizations_Extended;

        SET @Step = N'Build medications';
        RAISERROR(N'3.5 Building medications...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Medications_Extended;

        SET @Step = N'Build flowsheets';
        RAISERROR(N'3.6 Building flowsheets...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Flowsheets_Extended;

        SET @Step = N'Build patient provided information';
        RAISERROR(N'3.7 Building patient provided information...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_PatientProvidedInfo_Extended;


        /* =====================================================
           4. LABS
           ===================================================== */

        SET @Step = N'Build labs';
        RAISERROR(N'4.1 Building labs...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Labs_Extended;

        SET @Step = N'Build blood bank labs';
        RAISERROR(N'4.2 Building blood bank labs...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Labs_BloodBank_Extended;

        SET @Step = N'Build microbiology labs';
        RAISERROR(N'4.3 Building microbiology labs...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_Labs_Microbiology_Extended;


        /* =====================================================
           5. UNSTRUCTURED / REPORTS
           ===================================================== */

        SET @Step = N'Build clinical narrative';
        RAISERROR(N'5.1 Building clinical narrative...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_ClinicalNarrative_Extended;

        /*
           ClinicalNotes intentionally not part of official full build.

           Reason:
           tbl_FCAP1A_ClinicalNarrative_Extended is the master note source.
           Use ClinicalNotes only for QA/reconciliation if needed.

           EXEC dbo.usp_Build_FCAP1A_ClinicalNotes_Extended;
        */

        SET @Step = N'Build pathology reports';
        RAISERROR(N'5.2 Building pathology reports...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_PathologyReports_Extended;

        SET @Step = N'Build pathology EHR';
        RAISERROR(N'5.3 Building pathology EHR...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_PathologyEHR_Extended;

        SET @Step = N'Build radiology reports';
        RAISERROR(N'5.4 Building radiology reports...', 10, 1) WITH NOWAIT;
        EXEC dbo.usp_Build_FCAP1A_RadiologyReports_Extended;


        /* =====================================================
           6. BATCH ALLOCATION
           ===================================================== */

        SET @Step = N'Build FCAP 1A cohort 10 percent batches';
        RAISERROR(N'6. Building FCAP 1A cohort 10 percent richness batches...', 10, 1) WITH NOWAIT;

        EXEC dbo.usp_Build_FCAP1A_Cohort10_Batches
            @SeedDefaultConfig = 1,
            @ResetOutput = 1,
            @LongTextThreshold = 3000,
            @VeryLongTextThreshold = 8000;


        /* =====================================================
           7. MASTER SUCCESS LOG
           ===================================================== */

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended', 'U') IS NOT NULL
        BEGIN
            SELECT @TotalEligible = COUNT(*)
            FROM dbo.tbl_FCAP1A_Cohort10_Extended WITH (NOLOCK);
        END;

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Batches', 'U') IS NOT NULL
        BEGIN
            SELECT @FinalBatchRows = COUNT(*)
            FROM dbo.tbl_FCAP1A_Cohort10_Batches WITH (NOLOCK);
        END;

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
            'FCAP1A_FullBuild',
            NULL,
            NULL,
            @TotalEligible,
            @FinalBatchRows,
            SYSTEM_USER,
            NULL,
            CONCAT(
                'FCAP 1A full build completed successfully. ',
                'FinalStep=', @Step,
                '; CohortRows=', COALESCE(CONVERT(NVARCHAR(20), @TotalEligible), 'NULL'),
                '; BatchRows=', COALESCE(CONVERT(NVARCHAR(20), @FinalBatchRows), 'NULL')
            )
        );

        RAISERROR(N'FCAP 1A full build completed successfully.', 10, 1) WITH NOWAIT;

    END TRY

    BEGIN CATCH

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended', 'U') IS NOT NULL
        BEGIN
            SELECT @TotalEligible = COUNT(*)
            FROM dbo.tbl_FCAP1A_Cohort10_Extended WITH (NOLOCK);
        END;

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Batches', 'U') IS NOT NULL
        BEGIN
            SELECT @FinalBatchRows = COUNT(*)
            FROM dbo.tbl_FCAP1A_Cohort10_Batches WITH (NOLOCK);
        END;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        SET @ErrMsg =
            LEFT(
                CONCAT(
                    'FCAP 1A full build failed at step: ',
                    COALESCE(@Step, N'Unknown step'),
                    '. Original error: ',
                    ERROR_MESSAGE()
                ),
                4000
            );

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
                'FCAP1A_FullBuild',
                NULL,
                NULL,
                @TotalEligible,
                @FinalBatchRows,
                SYSTEM_USER,
                @ErrMsg,
                CONCAT(
                    'FCAP 1A full build failed. ',
                    'FailedStep=', COALESCE(@Step, N'Unknown step'),
                    '; CohortRows=', COALESCE(CONVERT(NVARCHAR(20), @TotalEligible), 'NULL'),
                    '; BatchRows=', COALESCE(CONVERT(NVARCHAR(20), @FinalBatchRows), 'NULL')
                )
            );
        END;

        SET @ThrowMsg = LEFT(@ErrMsg, 2048);

        THROW 51000, @ThrowMsg, 1;

    END CATCH;
END;
GO