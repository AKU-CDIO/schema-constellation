/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Labs_Microbiology_Extended]    Script Date: 7/13/2026 5:18:38 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure: usp_Build_FCAP1A_Labs_Microbiology_Extended

    Purpose:
        Builds the Extended scope version of the FCAP 1A Microbiology dataset.

        - Extracts microbiology findings and associated free-text comments.
        - Restricts processing to the FCAP 10 percent Extended cohort
          (tbl_FCAP1A_Cohort10_Extended), anchored through AdmVisits.
        - Applies the fixed Extended window:
              2022-11-05  →  2026-01-31
			  later updated to 2022-11-05  →  2026-06-14
        - Preserves original joins, transformations, deduplication logic,
          and field mappings exactly as implemented in the base procedure.
        - Enriches procedure names from DMicProcs using latest RowUpdateDateTime.
        - Logs execution metadata to dbo.FCAP1A_Cohort_Log with
          DataTopic = 'Labs_Microbiology_Extended'.

    Data Lineage:
        Source system: Meditech (AKULivendb via linked server NBIDRSRV)
        Target schema: CDIO_MeditechDB.dbo
        Output tables:
            - dbo.tbl_FCAP1A_Labs_Microbiology_Findings_Extended
            - dbo.tbl_FCAP1A_Labs_Microbiology_Comments_Extended

    Author      : Allan Zablon
    Organization: Aga Khan University – Data Innovation Office
    Version     : FCAP 1A – Labs Microbiology Extended
    Development : 2026-02-23
	Revision : 2026-06-14
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Labs_Microbiology_Extended]
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_WARNINGS ON;

    DECLARE
        @RunStart        DATETIME = SYSDATETIME(),
        @RunEnd          DATETIME,
        @DurationSeconds INT,
        @TotalEligible   INT = 0,
        @FindingsCount   INT = 0,
        @CommentsCount   INT = 0,
        @RecordCount     INT = 0,
        @WindowStart     DATE = '2022-11-05',
        @WindowEnd       DATE = '2026-06-14',
        @WindowEndPlus1  DATE = DATEADD(DAY,1,'2026-06-14');

    ------------------------------------------------------------------
    -- Ensure log table exists
    ------------------------------------------------------------------
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log
        (
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

    BEGIN TRY

        ------------------------------------------------------------------
        -- Drop & recreate FCAP-facing tables
        ------------------------------------------------------------------
        IF OBJECT_ID('dbo.tbl_FCAP1A_Labs_Microbiology_Findings_Extended','U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_Labs_Microbiology_Findings_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_Labs_Microbiology_Findings_Extended
        (
            MicroFindingRowID INT IDENTITY(1,1) PRIMARY KEY,
            PatientID         NVARCHAR(255) NOT NULL,
            VisitID           NVARCHAR(255) NOT NULL,
            SourceID          VARCHAR(3)    NOT NULL,
            SpecimenID        NVARCHAR(255) NOT NULL,
            ProcedureID       NVARCHAR(255) NOT NULL,
            ProcedureName     NVARCHAR(255) NULL,
            ResultDateTime    DATETIME      NULL,
            RowUpdateDateTime DATETIME      NULL,
            ExtractedOn       DATETIME      NOT NULL DEFAULT GETDATE()
        );

        IF OBJECT_ID('dbo.tbl_FCAP1A_Labs_Microbiology_Comments_Extended','U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_Labs_Microbiology_Comments_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_Labs_Microbiology_Comments_Extended
        (
            MicroCommentRowID INT IDENTITY(1,1) PRIMARY KEY,
            PatientID         NVARCHAR(255) NOT NULL,
            VisitID           NVARCHAR(255) NOT NULL,
            SourceID          VARCHAR(3)    NOT NULL,
            SpecimenID        NVARCHAR(255) NOT NULL,
            ProcedureID       NVARCHAR(255) NOT NULL,
            TextSeqID         INT           NOT NULL,
            TextID            NUMERIC(19,0) NULL,
            TextLine          NVARCHAR(255) NULL,
            RowUpdateDateTime DATETIME      NULL,
            ExtractedOn       DATETIME      NOT NULL DEFAULT GETDATE()
        );

        ------------------------------------------------------------------
        -- Eligible cohort
        ------------------------------------------------------------------
        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ------------------------------------------------------------------
        -- Cohort visits (force CI collation)
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#CohortVisits') IS NOT NULL DROP TABLE #CohortVisits;

        SELECT DISTINCT
            c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
            v.VisitID   COLLATE SQL_Latin1_General_CP1_CI_AS AS VisitID
        INTO #CohortVisits
        FROM dbo.tbl_FCAP1A_Cohort10_Extended c
        JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v
          ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
           = v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS;

        CREATE CLUSTERED INDEX CX_CohortVisits
            ON #CohortVisits(VisitID);

        ------------------------------------------------------------------
        -- Microbiology spine (DEDUP + force CI collation on keys)
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#MicroSpine') IS NOT NULL DROP TABLE #MicroSpine;

        ;WITH Dedup AS
        (
            SELECT
                o.SourceID,
                o.SpecimenID,
                o.ProcedureID,
                o.VisitID,
                MAX(o.RowUpdateDateTime) AS RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.LabVisitIsolatedOrganisms o
            JOIN #CohortVisits cv
              ON o.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS = cv.VisitID
            GROUP BY o.SourceID, o.SpecimenID, o.ProcedureID, o.VisitID
        )
        SELECT
            cv.PatientID                                                   AS PatientID,
            d.VisitID      COLLATE SQL_Latin1_General_CP1_CI_AS            AS VisitID,
            d.SourceID     COLLATE SQL_Latin1_General_CP1_CI_AS            AS SourceID,
            d.SpecimenID   COLLATE SQL_Latin1_General_CP1_CI_AS            AS SpecimenID,
            d.ProcedureID  COLLATE SQL_Latin1_General_CP1_CI_AS            AS ProcedureID,
            d.RowUpdateDateTime
        INTO #MicroSpine
        FROM Dedup d
        JOIN #CohortVisits cv
          ON d.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS = cv.VisitID;

        CREATE CLUSTERED INDEX CX_MicroSpine
            ON #MicroSpine(SourceID, SpecimenID, ProcedureID);

        ------------------------------------------------------------------
        -- Procedure dictionary (dedup + force CI)
        ------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#MicProcDict') IS NOT NULL DROP TABLE #MicProcDict;

        ;WITH P AS
        (
            SELECT
                ProcedureID COLLATE SQL_Latin1_General_CP1_CI_AS AS ProcedureID,
                Name        COLLATE SQL_Latin1_General_CP1_CI_AS AS Name,
                ROW_NUMBER() OVER
                (
                    PARTITION BY ProcedureID
                    ORDER BY RowUpdateDateTime DESC
                ) rn
            FROM [NBIDRSRV2].[AKULivendb].dbo.DMicProcs
        )
        SELECT ProcedureID, Name
        INTO #MicProcDict
        FROM P
        WHERE rn = 1;

        CREATE CLUSTERED INDEX CX_MicProcDict
            ON #MicProcDict(ProcedureID);

        ------------------------------------------------------------------
        -- Insert Findings (FCAP-facing)
        ------------------------------------------------------------------
        INSERT INTO dbo.tbl_FCAP1A_Labs_Microbiology_Findings_Extended
        (
            PatientID, VisitID, SourceID, SpecimenID,
            ProcedureID, ProcedureName,
            ResultDateTime, RowUpdateDateTime
        )
        SELECT
            ms.PatientID,
            ms.VisitID,
            ms.SourceID,
            ms.SpecimenID,
            ms.ProcedureID,
            pd.Name AS ProcedureName,
            ms.RowUpdateDateTime AS ResultDateTime,
            ms.RowUpdateDateTime
        FROM #MicroSpine ms
        LEFT JOIN #MicProcDict pd
          ON pd.ProcedureID = ms.ProcedureID;

        SELECT @FindingsCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_Labs_Microbiology_Findings_Extended;

        ------------------------------------------------------------------
        -- Insert Comments (force CI on join keys, DISTINCT to avoid repeats)
        ------------------------------------------------------------------
        INSERT INTO dbo.tbl_FCAP1A_Labs_Microbiology_Comments_Extended
        (
            PatientID, VisitID, SourceID, SpecimenID,
            ProcedureID, TextSeqID, TextID, TextLine, RowUpdateDateTime
        )
        SELECT DISTINCT
            ms.PatientID,
            ms.VisitID,
            CAST(t.SourceID AS VARCHAR(3))                                  AS SourceID,
            t.SpecimenID  COLLATE SQL_Latin1_General_CP1_CI_AS              AS SpecimenID,
            t.ProcedureID COLLATE SQL_Latin1_General_CP1_CI_AS              AS ProcedureID,
            t.TextSeqID,
            t.TextID,
            CAST(t.TextLine AS NVARCHAR(255))                               AS TextLine,
            t.RowUpdateDateTime
        FROM [NBIDRSRV2].[AKULivendb].dbo.MicSpecimenResultsText t
        JOIN #MicroSpine ms
          ON t.SourceID    COLLATE SQL_Latin1_General_CP1_CI_AS = ms.SourceID
         AND t.SpecimenID  COLLATE SQL_Latin1_General_CP1_CI_AS = ms.SpecimenID
         AND t.ProcedureID COLLATE SQL_Latin1_General_CP1_CI_AS = ms.ProcedureID
        WHERE t.RowUpdateDateTime >= @WindowStart
          AND t.RowUpdateDateTime <  @WindowEndPlus1;

        SELECT @CommentsCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_Labs_Microbiology_Comments_Extended;

        ------------------------------------------------------------------
        -- Guardrails: cohort scope must be intact
        ------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM dbo.tbl_FCAP1A_Labs_Microbiology_Findings_Extended WHERE PatientID IS NULL OR VisitID IS NULL)
            THROW 51011, 'Cohort scope breach: NULL PatientID or VisitID in Microbiology_Findings.', 1;

        IF EXISTS (SELECT 1 FROM dbo.tbl_FCAP1A_Labs_Microbiology_Comments_Extended WHERE PatientID IS NULL OR VisitID IS NULL)
            THROW 51012, 'Cohort scope breach: NULL PatientID or VisitID in Microbiology_Comments.', 1;

        ------------------------------------------------------------------
        -- Logging
        ------------------------------------------------------------------
        SET @RecordCount = @FindingsCount + @CommentsCount;
        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND,@RunStart,@RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd,
            TotalEligible, RecordCount, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
            N'Labs_Microbiology_Extended', @WindowStart, @WindowEnd,
            @TotalEligible, @RecordCount,
            CONCAT(N'Findings=',@FindingsCount, N', Comments=',@CommentsCount)
        );

        PRINT 'Labs_Microbiology rebuild completed successfully.';
        PRINT 'Findings rows: ' + CAST(@FindingsCount AS VARCHAR(20));
        PRINT 'Comments rows: ' + CAST(@CommentsCount AS VARCHAR(20));
        PRINT 'Total rows: ' + CAST(@RecordCount AS VARCHAR(20));
        PRINT 'Duration (seconds): ' + CAST(@DurationSeconds AS VARCHAR(20));

    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND,@RunStart,@RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds,
            RunStatus, DataTopic, WindowStart, WindowEnd,
            TotalEligible, RecordCount, ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds,
            'FAILED', N'Labs_Microbiology_Extended', @WindowStart, @WindowEnd,
            @TotalEligible, NULL, @Err, N'Error during Labs_Microbiology rebuild.'
        );

        THROW;
    END CATCH;
END;
