/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_ClinicalNarrative_Extended]    Script Date: 7/13/2026 12:33:23 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_ClinicalNarrative_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart DATETIME2(3) = SYSDATETIME(),
        @RunEnd DATETIME2(3),
        @DurationSeconds INT,
        @WindowStart DATE = '2022-11-05',
        @WindowEnd DATE = '2026-06-14',
        @WindowEndNextDay DATE,
        @TotalCohort INT,
        @RecordCount INT;

    SET @WindowEndNextDay = DATEADD(DAY, 1, @WindowEnd);

    BEGIN TRY

        SELECT @TotalCohort = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        IF OBJECT_ID('dbo.tbl_FCAP1A_ClinicalNarrative_Extended','U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_ClinicalNarrative_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_ClinicalNarrative_Extended
        (
            PatientID      NVARCHAR(50)   NOT NULL,
            VisitID        NVARCHAR(50)   NULL,
            DocumentID     NVARCHAR(250)  NOT NULL,
            SourceType     NVARCHAR(50)   NOT NULL,
            DocumentName   NVARCHAR(255)  NULL,
            DocumentStatus NVARCHAR(100)  NULL,
            NarrativeText  NVARCHAR(MAX)  NULL,
            LastUpdated    DATETIME       NULL,
            ExtractedOn    DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME(),

            CONSTRAINT PK_tbl_FCAP1A_ClinicalNarrative_Extended
                PRIMARY KEY CLUSTERED (PatientID, SourceType, DocumentID)
        );

        ;WITH EMR_Raw AS
        (
            SELECT
                c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
                v.VisitID   COLLATE SQL_Latin1_General_CP1_CI_AS AS VisitID,
                CAST(n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS AS NVARCHAR(250)) AS DocumentID,
                t.TextSeqID,
                t.TextLine,
                t.RowUpdateDateTime,
                ROW_NUMBER() OVER
                (
                    PARTITION BY 
                        c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS,
                        n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS,
                        t.TextSeqID
                    ORDER BY t.RowUpdateDateTime DESC
                ) rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.EmrDocData_NoteText_Text t
            JOIN [NBIDRSRV2].[AKULiveATdb].dbo.EmrDocData_Note n
                ON t.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS
            JOIN [NBIDRSRV2].[AKULiveATdb].dbo.EmrDocData_Main m
                ON n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   m.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS
            JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v
                ON m.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   v.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            JOIN dbo.tbl_FCAP1A_Cohort10_Extended c
                ON v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE
                t.RowUpdateDateTime >= @WindowStart
                AND t.RowUpdateDateTime < @WindowEndNextDay
        ),
        EMR_Merged AS
        (
            SELECT
                PatientID,
                VisitID,
                DocumentID,
                'EMR_NOTE' AS SourceType,
                STRING_AGG(CAST(TextLine AS NVARCHAR(MAX)), CHAR(10))
                    WITHIN GROUP (ORDER BY TextSeqID) AS NarrativeText,
                MAX(RowUpdateDateTime) AS LastUpdated
            FROM EMR_Raw
            WHERE rn = 1
              AND TextLine IS NOT NULL
              AND LTRIM(RTRIM(TextLine)) <> ''
              AND UPPER(LTRIM(RTRIM(TextLine))) <> 'NULL'
            GROUP BY PatientID, VisitID, DocumentID
        ),
        ITS_Base AS
        (
            SELECT
                c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
                a.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS AS VisitID,
                a.ReportID,
                a.Name,
                a.Status,
                b.TextSeqID,
                b.TextLine,
                b.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.ItsResult a
            JOIN [NBIDRSRV2].[AKULivendb].dbo.ItsResultCompiledText b
                ON a.ResultID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   b.ResultID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND a.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   b.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
            JOIN [NBIDRSRV2].[AKULiveATdb].dbo.RegAcct_Main ra
                ON a.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ra.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND a.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   ra.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
            JOIN dbo.tbl_FCAP1A_Cohort10_Extended c
                ON ra.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE
                a.SourceID = 'AKU'
                AND b.TextLine IS NOT NULL
                AND LTRIM(RTRIM(b.TextLine)) <> ''
                AND UPPER(LTRIM(RTRIM(b.TextLine))) <> 'NULL'
        ),
        ITS_Merged AS
        (
            SELECT *
            FROM
            (
                SELECT
                    PatientID,
                    VisitID,
                    CAST(ReportID COLLATE SQL_Latin1_General_CP1_CI_AS AS NVARCHAR(250)) AS DocumentID,
                    'ITS_REPORT' AS SourceType,
                    Name,
                    Status,
                    STRING_AGG(CAST(TextLine AS NVARCHAR(MAX)), CHAR(10))
                        WITHIN GROUP (ORDER BY TextSeqID) AS NarrativeText,
                    MAX(RowUpdateDateTime) AS LastUpdated,
                    ROW_NUMBER() OVER
                    (
                        PARTITION BY PatientID, ReportID
                        ORDER BY MAX(RowUpdateDateTime) DESC
                    ) rn
                FROM ITS_Base
                GROUP BY PatientID, VisitID, ReportID, Name, Status
            ) x
            WHERE rn = 1
        )

        INSERT INTO dbo.tbl_FCAP1A_ClinicalNarrative_Extended
        (
            PatientID,
            VisitID,
            DocumentID,
            SourceType,
            DocumentName,
            DocumentStatus,
            NarrativeText,
            LastUpdated
        )
        SELECT PatientID, VisitID, DocumentID, SourceType, NULL, NULL, NarrativeText, LastUpdated
        FROM EMR_Merged

        UNION ALL

        SELECT PatientID, VisitID, DocumentID, SourceType, Name, Status, NarrativeText, LastUpdated
        FROM ITS_Merged;

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_ClinicalNarrative_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd,
            TotalEligible, RecordCount, ProcessedBy, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
            'ClinicalNarrative_Extended',
            @WindowStart, @WindowEnd,
            @TotalCohort, @RecordCount, SYSTEM_USER,
            'Unified clinical narrative built successfully (collation-safe).'
        );

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;

END;
