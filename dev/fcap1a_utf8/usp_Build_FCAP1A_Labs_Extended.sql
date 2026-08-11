/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Labs_Extended]    Script Date: 7/13/2026 1:20:13 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Labs_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE 
        @RunStart              DATETIME = SYSDATETIME(),
        @RunEnd                DATETIME,
        @DurationSeconds       INT,
        @RecordCount           INT = 0,
        @TotalEligible         INT = 0,
        @WindowStart           DATE = '2022-11-05',
        @WindowEnd             DATE = '2026-06-14',
        @WindowEndPlus1        DATE = DATEADD(DAY, 1, '2026-06-14'),
        @ResultsCount          INT = 0,
        @SpecimenCommentsCount INT = 0,
        @ResultCommentsCount   INT = 0;


    ----------------------------------------------------------------------
    -- 1) Ensure log table exists
    ----------------------------------------------------------------------
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME        NOT NULL,
            RunEnd          DATETIME        NULL,
            DurationSeconds INT             NULL,
            RunStatus       VARCHAR(20)     NOT NULL,
            DataTopic       NVARCHAR(100)   NOT NULL,
            WindowStart     DATE            NULL,
            WindowEnd       DATE            NULL,
            TotalEligible   INT             NULL,
            RecordCount     INT             NULL,
            ProcessedBy     NVARCHAR(100)   NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000)  NULL,
            Remarks         NVARCHAR(4000)  NULL
        );
    END;


    ----------------------------------------------------------------------
    -- 2) Drop and recreate target tables
    ----------------------------------------------------------------------
    IF OBJECT_ID('dbo.tbl_FCAP1A_Labs_Results_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Labs_Results_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Labs_Results_Extended (
        LabRowID             INT IDENTITY(1,1) PRIMARY KEY,

        PatientID            NVARCHAR(255) NOT NULL,
        VisitID              NVARCHAR(255) NULL,
        SpecimenID           NVARCHAR(255) NOT NULL,
        TestID               NVARCHAR(255) NOT NULL,   -- TestPrintNumberID
        TestName             NVARCHAR(255) NULL,       -- ResultGroup

        -- Enrichment from DLabTest
        CanonicalTestName    NVARCHAR(255) NULL,       -- DLabTest.Name
        TestMnemonic         NVARCHAR(100) NULL,       -- DLabTest.Mnemonic

        NumericResult        DECIMAL(20,7) NULL,
        AlphaResult          NVARCHAR(255) NULL,
        Units                NVARCHAR(50)  NULL,
        AbnormalFlag         NVARCHAR(10)  NULL,
        ReferenceRange       NVARCHAR(255) NULL,

        ResultDateTime       DATETIME      NULL,
        VerificationDateTime DATETIME      NULL,
        CollectionDateTime   DATETIME      NULL,
        ReceivedDateTime     DATETIME      NULL,
        Priority             NVARCHAR(50)  NULL,

        OrganismID           NVARCHAR(255) NULL,
        ProcedureID          NVARCHAR(255) NULL,

        SourceID             VARCHAR(3)    NOT NULL,
        RowUpdateDateTime    DATETIME      NULL,
        ExtractedOn          DATETIME      NOT NULL DEFAULT GETDATE()
    );


    IF OBJECT_ID('dbo.tbl_FCAP1A_Labs_SpecimenComments_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Labs_SpecimenComments_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Labs_SpecimenComments_Extended (
        SpecimenCommentRowID INT IDENTITY(1,1) PRIMARY KEY,

        PatientID            NVARCHAR(255) NOT NULL,
        VisitID              NVARCHAR(255) NULL,
        SpecimenID           NVARCHAR(255) NOT NULL,

        TextSeqID            INT NOT NULL,
        TextID               NUMERIC(19,0) NULL,
        TextLine             NVARCHAR(255) NULL,

        RowUpdateDateTime    DATETIME NULL,
        SourceID             VARCHAR(3) NOT NULL,
        ExtractedOn          DATETIME NOT NULL DEFAULT GETDATE()
    );


    IF OBJECT_ID('dbo.tbl_FCAP1A_Labs_ResultComments_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Labs_ResultComments_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Labs_ResultComments_Extended (
        ResultCommentRowID   INT IDENTITY(1,1) PRIMARY KEY,

        PatientID            NVARCHAR(255) NOT NULL,
        VisitID              NVARCHAR(255) NULL,
        SpecimenID           NVARCHAR(255) NOT NULL,
        TestID               NVARCHAR(255) NOT NULL,

        TextSeqID            INT NOT NULL,
        TextID               NUMERIC(19,0) NULL,
        TextLine             NVARCHAR(255) NULL,

        RowUpdateDateTime    DATETIME NULL,
        SourceID             VARCHAR(3) NOT NULL,
        ExtractedOn          DATETIME NOT NULL DEFAULT GETDATE()
    );



    BEGIN TRY

        ------------------------------------------------------------------
        -- 3) Total eligible patients in FCAP 10 percent cohort
        ------------------------------------------------------------------
        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;


        ------------------------------------------------------------------
        -- 4) Stage cohort visits (PatientID + VisitID)
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#CohortVisits') IS NOT NULL DROP TABLE #CohortVisits;

        SELECT DISTINCT
            c.PatientID,
            v.VisitID
        INTO #CohortVisits
        FROM dbo.tbl_FCAP1A_Cohort10_Extended AS c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS;


        ------------------------------------------------------------------
        -- 5) Stage LabSpecimens
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#Specimens') IS NOT NULL DROP TABLE #Specimens;

        SELECT
            cv.PatientID,
            s.VisitID,
            s.SourceID,
            s.SpecimenID,
            s.Priority,
            s.CollectionDateTime,
            s.ReceivedDateTime,
            s.RowUpdateDateTime
        INTO #Specimens
        FROM [NBIDRSRV2].[AKULivendb].dbo.LabSpecimens AS s
        INNER JOIN #CohortVisits AS cv
            ON cv.VisitID = s.VisitID
        WHERE COALESCE(s.CollectionDateTime, s.ReceivedDateTime, s.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(s.CollectionDateTime, s.ReceivedDateTime, s.RowUpdateDateTime) <  @WindowEndPlus1;


        ------------------------------------------------------------------
        -- 6) Stage LabSpecimenTests
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#Tests') IS NOT NULL DROP TABLE #Tests;

        SELECT
            sp.PatientID,
            sp.VisitID,
            t.SourceID,
            t.SpecimenID,
            t.TestPrintNumberID,
            t.ResultGroup,
            t.NumericResult,
            t.ResultRW,
            t.Units,
            t.AbnormalFlag,
            t.NormalRange,
            t.ResultDateTime,
            t.VerifyDateTime,
            t.RowUpdateDateTime
        INTO #Tests
        FROM [NBIDRSRV2].[AKULivendb].dbo.LabSpecimenTests AS t
        INNER JOIN #Specimens AS sp
            ON t.SourceID = sp.SourceID
           AND t.SpecimenID = sp.SpecimenID
        WHERE COALESCE(t.ResultDateTime, t.RowUpdateDateTime) >= @WindowStart
          AND COALESCE(t.ResultDateTime, t.RowUpdateDateTime) <  @WindowEndPlus1;


        ------------------------------------------------------------------
        -- 7) Stage microbiology organisms
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#Micro') IS NOT NULL DROP TABLE #Micro;

        SELECT DISTINCT
            sp.PatientID,
            sp.VisitID,
            m.SourceID,
            m.SpecimenID,
            m.OrganismID,
            m.ProcedureID,
            m.RowUpdateDateTime
        INTO #Micro
        FROM [NBIDRSRV2].[AKULivendb].dbo.LabVisitIsolatedOrganisms AS m
        INNER JOIN #Specimens AS sp
            ON m.SourceID   = sp.SourceID
           AND m.SpecimenID = sp.SpecimenID
           AND m.VisitID    = sp.VisitID;


        ------------------------------------------------------------------
        -- 8) Insert structured Lab results (with enrichment)
        ------------------------------------------------------------------

        ;WITH DedupTest AS (
            SELECT
                PrintNumberID,
                Name,
                Mnemonic,
                ROW_NUMBER() OVER (
                    PARTITION BY PrintNumberID
                    ORDER BY RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV2].[AKULivendb].dbo.DLabTest
        )
        INSERT INTO dbo.tbl_FCAP1A_Labs_Results_Extended (
            PatientID,
            VisitID,
            SpecimenID,
            TestID,
            TestName,
            CanonicalTestName,
            TestMnemonic,
            NumericResult,
            AlphaResult,
            Units,
            AbnormalFlag,
            ReferenceRange,
            ResultDateTime,
            VerificationDateTime,
            CollectionDateTime,
            ReceivedDateTime,
            Priority,
            OrganismID,
            ProcedureID,
            SourceID,
            RowUpdateDateTime
        )
        SELECT
            t.PatientID,
            t.VisitID,
            t.SpecimenID,
            t.TestPrintNumberID     AS TestID,
            t.ResultGroup           AS TestName,

            dt.Name     COLLATE SQL_Latin1_General_CP1_CI_AS AS CanonicalTestName,
            dt.Mnemonic COLLATE SQL_Latin1_General_CP1_CI_AS AS TestMnemonic,

            t.NumericResult,
            t.ResultRW              AS AlphaResult,
            t.Units,
            t.AbnormalFlag,
            t.NormalRange           AS ReferenceRange,
            t.ResultDateTime,
            t.VerifyDateTime,
            sp.CollectionDateTime,
            sp.ReceivedDateTime,
            sp.Priority,
            mi.OrganismID,
            mi.ProcedureID,
            t.SourceID,
            COALESCE(t.RowUpdateDateTime, sp.RowUpdateDateTime, mi.RowUpdateDateTime)
        FROM #Tests AS t
        INNER JOIN #Specimens AS sp
            ON t.SourceID   = sp.SourceID
           AND t.SpecimenID = sp.SpecimenID
        LEFT JOIN #Micro AS mi
            ON t.SourceID   = mi.SourceID
           AND t.SpecimenID = mi.SpecimenID
           AND t.VisitID    = mi.VisitID
        LEFT JOIN DedupTest dt
            ON dt.rn = 1
           AND dt.PrintNumberID COLLATE SQL_Latin1_General_CP1_CI_AS
               = t.TestPrintNumberID COLLATE SQL_Latin1_General_CP1_CI_AS;


        ------------------------------------------------------------------
        -- 9) Insert specimen comments
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#SpecimenComments') IS NOT NULL DROP TABLE #SpecimenComments;

        SELECT
            sp.PatientID,
            sp.VisitID,
            c.SpecimenID,
            c.TextSeqID,
            c.TextID,
            c.TextLine,
            c.RowUpdateDateTime,
            c.SourceID
        INTO #SpecimenComments
        FROM [NBIDRSRV2].[AKULivendb].dbo.LabSpecimenCommentsText AS c
        INNER JOIN #Specimens AS sp
            ON c.SourceID   = sp.SourceID
           AND c.SpecimenID = sp.SpecimenID;

        INSERT INTO dbo.tbl_FCAP1A_Labs_SpecimenComments_Extended (
            PatientID,
            VisitID,
            SpecimenID,
            TextSeqID,
            TextID,
            TextLine,
            RowUpdateDateTime,
            SourceID
        )
        SELECT
            PatientID,
            VisitID,
            SpecimenID,
            TextSeqID,
            TextID,
            TextLine,
            RowUpdateDateTime,
            SourceID
        FROM #SpecimenComments;


        ------------------------------------------------------------------
        -- 10) Insert result comments
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#ResultComments') IS NOT NULL DROP TABLE #ResultComments;

        SELECT
            sp.PatientID,
            sp.VisitID,
            rc.SpecimenID,
            rc.PrintNumberID AS TestID,
            rc.TextSeqID,
            rc.TextID,
            rc.TextLine,
            rc.RowUpdateDateTime,
            rc.SourceID
        INTO #ResultComments
        FROM [NBIDRSRV2].[AKULivendb].dbo.LabPatientResultCommentsText AS rc
        INNER JOIN #Specimens AS sp
            ON rc.SourceID   = sp.SourceID
           AND rc.SpecimenID = sp.SpecimenID
        INNER JOIN #Tests AS t
            ON t.SourceID = rc.SourceID
           AND t.SpecimenID = rc.SpecimenID
           AND t.TestPrintNumberID = rc.PrintNumberID

        UNION ALL

        SELECT
            sp2.PatientID,
            sp2.VisitID,
            rc2.SpecimenID,
            rc2.TestPrintNumberID AS TestID,
            rc2.TextSeqID,
            rc2.TextID,
            rc2.TextLine,
            rc2.RowUpdateDateTime,
            rc2.SourceID
        FROM [NBIDRSRV2].[AKULivendb].dbo.LabSpecimenResultCommentsText AS rc2
        INNER JOIN #Specimens AS sp2
            ON rc2.SourceID   = sp2.SourceID
           AND rc2.SpecimenID = sp2.SpecimenID
        INNER JOIN #Tests AS t2
            ON t2.SourceID = rc2.SourceID
           AND t2.SpecimenID = rc2.SpecimenID
           AND t2.TestPrintNumberID = rc2.TestPrintNumberID;


        INSERT INTO dbo.tbl_FCAP1A_Labs_ResultComments_Extended (
            PatientID,
            VisitID,
            SpecimenID,
            TestID,
            TextSeqID,
            TextID,
            TextLine,
            RowUpdateDateTime,
            SourceID
        )
        SELECT
            PatientID,
            VisitID,
            SpecimenID,
            TestID,
            TextSeqID,
            TextID,
            TextLine,
            RowUpdateDateTime,
            SourceID
        FROM #ResultComments;


        ------------------------------------------------------------------
        -- 11) Log results
        ------------------------------------------------------------------
        SELECT @ResultsCount          = COUNT(*) FROM dbo.tbl_FCAP1A_Labs_Results_Extended;
        SELECT @SpecimenCommentsCount = COUNT(*) FROM dbo.tbl_FCAP1A_Labs_SpecimenComments_Extended;
        SELECT @ResultCommentsCount   = COUNT(*) FROM dbo.tbl_FCAP1A_Labs_ResultComments_Extended;

        SET @RecordCount = @ResultsCount + @SpecimenCommentsCount + @ResultCommentsCount;

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
            N'Labs_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            NULL,
            N'Labs rebuild: Results='
                + CAST(@ResultsCount AS NVARCHAR(20))
                + N', SpecimenComments='
                + CAST(@SpecimenCommentsCount AS NVARCHAR(20))
                + N', ResultComments='
                + CAST(@ResultCommentsCount AS NVARCHAR(20)) + N'.'
        );


        PRINT 'Labs rebuild completed successfully.';
        PRINT 'Results rows: ' + CAST(@ResultsCount AS VARCHAR(20));
        PRINT 'Specimen comments rows: ' + CAST(@SpecimenCommentsCount AS VARCHAR(20));
        PRINT 'Result comments rows: ' + CAST(@ResultCommentsCount AS VARCHAR(20));
        PRINT 'Total rows (all tables): ' + CAST(@RecordCount AS VARCHAR(20));
        PRINT 'Duration (seconds): ' + CAST(@DurationSeconds AS VARCHAR(20));


    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

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
            'FAILED',
            N'Labs_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            NULL,
            SYSTEM_USER,
            @Err,
            N'Error during Labs rebuild.'
        );

        THROW;
    END CATCH;

END;
