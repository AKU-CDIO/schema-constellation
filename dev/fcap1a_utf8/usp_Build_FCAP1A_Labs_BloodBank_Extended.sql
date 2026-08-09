USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Labs_BloodBank_Extended]    Script Date: 7/13/2026 5:18:08 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure: usp_Build_FCAP1A_Labs_BloodBank_Extended

    Purpose:
        Builds the Extended scope version of the FCAP 1A Blood Bank laboratory dataset.

        - Extracts Blood Bank test results from Meditech for the FCAP 10 percent Extended cohort
          (tbl_FCAP1A_Cohort10_Extended), anchored through AdmVisits.
        - Produces a lean, FCAP-facing output table containing:
            test identifiers, dictionary-enriched test names, clinical results,
            sign-out comment, and key timestamps.
        - Applies the fixed Extended window:
              2022-11-05  →  2026-01-31
			  updated to  >>
			  2022-11-05  →  2026-06-14
        - Preserves original logic, joins, transformations, and field mappings
          exactly as implemented in the base Blood Bank procedure.
        - Logs execution metadata to dbo.FCAP1A_Cohort_Log with
          DataTopic = 'Labs_BloodBank_Extended'.

    Data Lineage:
        Source system: Meditech (AKULivendb via linked server NBIDRSRV)
        Target schema: CDIO_MeditechDB.dbo
        Output table:
            - dbo.tbl_FCAP1A_Labs_BloodBank_Extended

    Author      : Allan Zablon
    Organization: Aga Khan University – Data Innovation Office
    Version     : FCAP 1A – Labs Blood Bank Extended
    Development : 2026-02-23
	Revision : 2026-06-14
*/
ALTER     PROCEDURE [dbo].[usp_Build_FCAP1A_Labs_BloodBank_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    ----------------------------------------------------------------------
    -- Runtime variables
    ----------------------------------------------------------------------
    DECLARE 
        @RunStart        DATETIME = SYSDATETIME(),
        @RunEnd          DATETIME,
        @DurationSeconds INT,
        @RecordCount     INT = 0,
        @TotalEligible   INT = 0,
        @WindowStart     DATE = '2022-11-05',
        @WindowEnd       DATE = '2026-06-14',
        @WindowEndPlus1  DATE = DATEADD(DAY, 1, '2026-06-14'),
        @ResultsCount    INT = 0;

    ----------------------------------------------------------------------
    -- Ensure shared log table exists
    ----------------------------------------------------------------------
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
            ProcessedBy     NVARCHAR(100) NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000) NULL,
            Remarks         NVARCHAR(4000) NULL
        );
    END;

    ----------------------------------------------------------------------
    -- Drop and recreate Blood Bank output table (LEAN version)
    ----------------------------------------------------------------------
    IF OBJECT_ID('dbo.tbl_FCAP1A_Labs_BloodBank_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Labs_BloodBank_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Labs_BloodBank_Extended
    (
        BloodBankRowID     INT IDENTITY(1,1) PRIMARY KEY,

        -- Cohort linkage
        PatientID          NVARCHAR(255) NOT NULL,
        VisitID            NVARCHAR(255) NULL,
        SpecimenID         NVARCHAR(255) NOT NULL,
        SourceID           VARCHAR(3)    NOT NULL,

        -- Dictionary (DBbkTests)
        TestPrintNumberID  NVARCHAR(255) NOT NULL,
        TestName           NVARCHAR(255) NULL,
        TestAbbreviation   NVARCHAR(255) NULL,
        TestType           NVARCHAR(255) NULL,

        -- Clinical Result
        ResultRW           NVARCHAR(255) NULL,
        NumericResult      DECIMAL(20,7) NULL,
        Units              NVARCHAR(255) NULL,
        AbnormalFlag       NVARCHAR(255) NULL,

        -- Single comment field (Blood Bank Only)
        SignOutComment     NVARCHAR(255) NULL,

        -- Result timestamps
        OrderDateTime      DATETIME NULL,
        OrderPriority      NVARCHAR(255) NULL,
        ResultDateTime     DATETIME NULL,
        VerifyDateTime     DATETIME NULL,

        -- Audit
        RowUpdateDateTime  DATETIME NULL,
        ExtractedOn        DATETIME NOT NULL DEFAULT GETDATE()
    );

    BEGIN TRY

        ----------------------------------------------------------------------
        -- Stage cohort visits
        ----------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#CohortVisits') IS NOT NULL DROP TABLE #CohortVisits;

        SELECT DISTINCT
            c.PatientID,
            v.VisitID
        INTO #CohortVisits
        FROM dbo.tbl_FCAP1A_Cohort10_Extended AS c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS;

        ----------------------------------------------------------------------
        -- Stage Blood Bank test rows
        ----------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#BbkTests') IS NOT NULL DROP TABLE #BbkTests;

        SELECT
            cv.PatientID,
            bb.VisitID,
            bb.SourceID,
            bb.SpecimenID,
            bb.TestPrintNumberID,
            bb.ResultRW,
            bb.NumericResult,
            bb.Units,
            bb.AbnormalFlag,
            bb.SignOutComment,
            bb.OrderDateTime,
            bb.OrderPriority,
            bb.ResultDateTime,
            bb.VerifyDateTime,
            bb.RowUpdateDateTime AS BbkRowUpdateDateTime
        INTO #BbkTests
        FROM [NBIDRSRV2].[AKULivendb].dbo.BbkSpecimenTests AS bb
        INNER JOIN #CohortVisits AS cv
            ON bb.VisitID = cv.VisitID
        WHERE COALESCE(bb.ResultDateTime, bb.OrderDateTime, bb.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(bb.ResultDateTime, bb.OrderDateTime, bb.RowUpdateDateTime) <  @WindowEndPlus1;

        ----------------------------------------------------------------------
        -- Stage dictionary (DBbkTests)
        ----------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#DBbkTests') IS NOT NULL DROP TABLE #DBbkTests;

        SELECT
            d.SourceID,
            d.PrintNumberID,
            d.Name,
            d.Abbreviation,
            d.Type
        INTO #DBbkTests
        FROM [NBIDRSRV2].[AKULivendb].dbo.DBbkTests AS d
        WHERE d.Active = 'Y' OR d.Active IS NULL;

        ----------------------------------------------------------------------
        -- Final INSERT into lean FCAP table
        ----------------------------------------------------------------------
        INSERT INTO dbo.tbl_FCAP1A_Labs_BloodBank_Extended
        (
            PatientID,
            VisitID,
            SpecimenID,
            SourceID,
            TestPrintNumberID,
            TestName,
            TestAbbreviation,
            TestType,
            ResultRW,
            NumericResult,
            Units,
            AbnormalFlag,
            SignOutComment,
            OrderDateTime,
            OrderPriority,
            ResultDateTime,
            VerifyDateTime,
            RowUpdateDateTime
        )
        SELECT
            bt.PatientID,
            bt.VisitID,
            bt.SpecimenID,
            bt.SourceID,
            bt.TestPrintNumberID,
            dict.Name,
            dict.Abbreviation,
            dict.Type,
            bt.ResultRW,
            bt.NumericResult,
            bt.Units,
            bt.AbnormalFlag,
            bt.SignOutComment,
            bt.OrderDateTime,
            bt.OrderPriority,
            bt.ResultDateTime,
            bt.VerifyDateTime,
            bt.BbkRowUpdateDateTime
        FROM #BbkTests AS bt
        LEFT JOIN #DBbkTests AS dict
            ON bt.SourceID = dict.SourceID
           AND bt.TestPrintNumberID = dict.PrintNumberID;

        ----------------------------------------------------------------------
        -- Log and finish
        ----------------------------------------------------------------------
        SELECT @ResultsCount = COUNT(*) FROM dbo.tbl_FCAP1A_Labs_BloodBank_Extended;

        SET @RecordCount = @ResultsCount;
        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd, TotalEligible,
            RecordCount, ProcessedBy, ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'Labs_BloodBank_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            NULL,
            N'Lean Blood Bank extract completed successfully.'
        );

        PRINT 'Blood Bank extraction complete.';
        PRINT 'Rows inserted: ' + CAST(@ResultsCount AS VARCHAR(20));
        PRINT 'Duration (seconds): ' + CAST(@DurationSeconds AS VARCHAR(20));

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd, TotalEligible,
            RecordCount, ProcessedBy, ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            N'Labs_BloodBank_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @Err,
            N'Error during lean Blood Bank rebuild.'
        );

        THROW;
    END CATCH;
END;