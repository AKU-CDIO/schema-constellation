USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure: usp_Build_FCAP1A_ClinicalNotes_Extended

    Author: Allan Zablon
    Development Date: 2026-02-22
    Version: Extended (Document-Level Only)

    Purpose:
        Builds tbl_FCAP1A_ClinicalNotes_Extended_Merged as a document-level
        clinical notes extract for the FCAP 1A Extended cohort.

        - Uses AdmVisits as anchor
        - Restricts to tbl_FCAP1A_Cohort10_Extended
        - Applies Extended window
        - Deduplicates lines using ROW_NUMBER()
        - Merges lines using STRING_AGG (NVARCHAR(MAX) safe)
        - Removes NULL, blank, and literal 'NULL'
        - Logs execution
*/
CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_ClinicalNotes_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart          DATETIME2(3) = SYSDATETIME(),
        @RunEnd            DATETIME2(3),
        @DurationSeconds   INT,
        @WindowStart       DATE = '2022-11-05',
        @WindowEnd         DATE = '2026-01-31',
        @WindowEndNextDay  DATE,
        @TotalCohort       INT,
        @RecordCount       INT;

    SET @WindowEndNextDay = DATEADD(DAY, 1, @WindowEnd);

    BEGIN TRY

        SELECT @TotalCohort = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        IF OBJECT_ID('dbo.tbl_FCAP1A_ClinicalNotes_Extended_Merged', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_ClinicalNotes_Extended_Merged;

        CREATE TABLE dbo.tbl_FCAP1A_ClinicalNotes_Extended_Merged
        (
            PatientID   NVARCHAR(50)   NOT NULL,
            VisitID     NVARCHAR(50)   NULL,
            DocumentID  NVARCHAR(250)  NOT NULL,
            NoteText    NVARCHAR(MAX)  NULL,
            LastUpdated DATETIME       NULL,
            ExtractedOn DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME(),

            CONSTRAINT PK_tbl_FCAP1A_ClinicalNotes_Extended_Merged
                PRIMARY KEY CLUSTERED (PatientID, DocumentID)
        );

        ;WITH RawLines AS
        (
            SELECT
                c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS AS PatientID,
                v.VisitID   COLLATE SQL_Latin1_General_CP1_CI_AS AS VisitID,
                CAST(n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS AS NVARCHAR(250)) AS DocumentID,
                t.TextSeqID,
                t.TextLine COLLATE SQL_Latin1_General_CP1_CI_AS AS TextLine,
                t.RowUpdateDateTime,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS,
                        n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS,
                        t.TextSeqID
                    ORDER BY
                        t.RowUpdateDateTime DESC
                ) AS rn
            FROM [NBIDRSRV].[AKULiveATdb].dbo.EmrDocData_NoteText_Text AS t
            INNER JOIN [NBIDRSRV].[AKULiveATdb].dbo.EmrDocData_Note AS n
                ON t.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS
            INNER JOIN [NBIDRSRV].[AKULiveATdb].dbo.EmrDocData_Main AS m
                ON n.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   m.EmrDocDataID COLLATE SQL_Latin1_General_CP1_CI_AS
            INNER JOIN [NBIDRSRV].[AKULivendb].dbo.AdmVisits AS v
                ON m.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   v.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended AS c
                ON v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE
                t.RowUpdateDateTime >= @WindowStart
                AND t.RowUpdateDateTime < @WindowEndNextDay
        )
        INSERT INTO dbo.tbl_FCAP1A_ClinicalNotes_Extended_Merged
        (
            PatientID,
            VisitID,
            DocumentID,
            NoteText,
            LastUpdated
        )
        SELECT
            r.PatientID,
            r.VisitID,
            r.DocumentID,
            STRING_AGG(
                CAST(r.TextLine AS NVARCHAR(MAX)),
                CHAR(10)
            ) WITHIN GROUP (ORDER BY r.TextSeqID),
            MAX(r.RowUpdateDateTime)
        FROM RawLines r
        WHERE
            r.rn = 1
            AND r.TextLine IS NOT NULL
            AND LTRIM(RTRIM(r.TextLine)) <> ''
            AND UPPER(LTRIM(RTRIM(r.TextLine))) <> 'NULL'
        GROUP BY
            r.PatientID,
            r.VisitID,
            r.DocumentID;

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_ClinicalNotes_Extended_Merged;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

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
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            'ClinicalNotes_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalCohort,
            @RecordCount,
            SYSTEM_USER,
            'Extended document-level clinical notes built successfully.'
        );

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;

END;
GO