/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_PathologyEHR_Extended]    Script Date: 7/13/2026 1:24:42 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_PathologyEHR_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart          DATETIME2(3) = SYSDATETIME(),
        @RunEnd            DATETIME2(3),
        @DurationSeconds   INT,
        @WindowStart       DATE = '2022-11-05',
        @WindowEnd         DATE = '2026-06-14',
        @WindowEndNextDay  DATE = DATEADD(DAY, 1, '2026-06-14'),
        @RecordCount       INT = 0;

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log', 'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log
        (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME2(3) NOT NULL,
            RunEnd          DATETIME2(3) NULL,
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

        IF OBJECT_ID('dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended;

        IF OBJECT_ID('dbo.tbl_FCAP1A_PathologyEHR_TextLines_Extended', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_PathologyEHR_TextLines_Extended;

        IF OBJECT_ID('dbo.tbl_FCAP1A_PathologyEHR_Extended', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_PathologyEHR_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended
        (
            PatientID         NVARCHAR(255) NOT NULL,
            VisitID           NVARCHAR(255) NOT NULL,
            SourceID          VARCHAR(3)    NOT NULL,
            SpecimenID        NVARCHAR(50)  NOT NULL,
            SectionType       NVARCHAR(30)  NOT NULL,
            SectionText       NVARCHAR(MAX) NOT NULL,
            RowUpdateDateTime DATETIME NULL,
            ExtractedOn       DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),

            CONSTRAINT PK_tbl_FCAP1A_PathologyEHR_TextBlocks_Extended
                PRIMARY KEY CLUSTERED
                (
                    PatientID,
                    VisitID,
                    SourceID,
                    SpecimenID,
                    SectionType
                )
        );

        CREATE TABLE dbo.tbl_FCAP1A_PathologyEHR_Extended
        (
            PathologyEHRRowID      INT IDENTITY(1,1) PRIMARY KEY,

            PatientID              NVARCHAR(255) NOT NULL,
            VisitID                NVARCHAR(255) NOT NULL,
            SourceID               VARCHAR(3)    NOT NULL,
            SpecimenID             NVARCHAR(50)  NOT NULL,
            AccessionNumber        NVARCHAR(100) NULL,

            NoteDate               DATE NULL,
            NoteDateTime           DATETIME NULL,
            NoteType               NVARCHAR(100) NOT NULL,
            NoteTitle              NVARCHAR(255) NULL,
            NoteStatus             NVARCHAR(100) NULL,

            PathologyCaseType      NVARCHAR(100) NULL,
            PathologyCaseStatus    NVARCHAR(100) NULL,
            ReceivedDateTime       DATETIME NULL,
            FinalReportDateTime    DATETIME NULL,

            AuthorProviderID       NVARCHAR(50) NULL,
            AuthorProviderName     NVARCHAR(255) NULL,
            PathologistUserID      NVARCHAR(50) NULL,

            PathologyText          NVARCHAR(MAX) NOT NULL,

            HasFindingsText        BIT NOT NULL DEFAULT 0,
            HasHistologyText       BIT NOT NULL DEFAULT 0,
            HasAddendumText        BIT NOT NULL DEFAULT 0,
            HasCommentText         BIT NOT NULL DEFAULT 0,
            HasCorrection          BIT NOT NULL DEFAULT 0,

            RecordSource           NVARCHAR(100) NOT NULL,
            ElementSourceID        NVARCHAR(255) NOT NULL,

            RowUpdateDateTime      DATETIME NOT NULL,
            ExtractedOn            DATETIME2(3) NOT NULL DEFAULT SYSDATETIME()
        );

        IF OBJECT_ID('tempdb..#Cases') IS NOT NULL DROP TABLE #Cases;
        IF OBJECT_ID('tempdb..#RawText') IS NOT NULL DROP TABLE #RawText;

        SELECT
            r.PatientID COLLATE DATABASE_DEFAULT AS PatientID,
            ps.VisitID COLLATE DATABASE_DEFAULT AS VisitID,
            ps.SourceID COLLATE DATABASE_DEFAULT AS SourceID,
            ps.SpecimenID COLLATE DATABASE_DEFAULT AS SpecimenID,

            AccessionNumber =
                COALESCE(
                    ps.NumberSort,
                    ps.SpecimenNumber,
                    CASE
                        WHEN ps.Prefix IS NOT NULL AND ps.NumberPartOnly IS NOT NULL
                            THEN ps.Prefix + CONVERT(VARCHAR(20), ps.NumberPartOnly)
                        WHEN ps.Prefix IS NOT NULL
                            THEN ps.Prefix
                        ELSE NULL
                    END
                ),

            PathologyCaseType   = COALESCE(ps.TypeOfSpec, ps.Type),
            PathologyCaseStatus = ps.Status,

            ReceivedDateTime    = ps.ReceivedDateTime,
            FinalReportDateTime = COALESCE(fs.DateTime, ps.FinalSignOutDateTime),

            NoteDateTime =
                COALESCE(
                    fs.DateTime,
                    ps.FinalSignOutDateTime,
                    ps.ReceivedDateTime,
                    ps.DateTime,
                    ps.RowUpdateDateTime
                ),

            AuthorProviderID =
                COALESCE(fs.SignOutUserID, ps.SubmProviderID),

            AuthorProviderName = ps.SubmProviderFreeEntryName,
            PathologistUserID  = fs.SignOutUserID,

            BaseRowUpdateDateTime = ps.RowUpdateDateTime
        INTO #Cases
        FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimens ps
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.RegAcct_Main r
            ON r.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               ps.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND r.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS =
               ps.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
        INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               r.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        OUTER APPLY
        (
            SELECT TOP 1
                fs.DateTime,
                fs.SignOutUserID
            FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimenFinalSignouts fs
            WHERE fs.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                  ps.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
              AND fs.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS =
                  ps.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS
            ORDER BY fs.DateTime DESC
        ) fs
        WHERE COALESCE(
                fs.DateTime,
                ps.FinalSignOutDateTime,
                ps.ReceivedDateTime,
                ps.DateTime,
                ps.RowUpdateDateTime
              ) >= @WindowStart
          AND COALESCE(
                fs.DateTime,
                ps.FinalSignOutDateTime,
                ps.ReceivedDateTime,
                ps.DateTime,
                ps.RowUpdateDateTime
              ) < @WindowEndNextDay;

        SELECT
            SourceID COLLATE DATABASE_DEFAULT AS SourceID,
            SpecimenID COLLATE DATABASE_DEFAULT AS SpecimenID,
            SectionType,
            LineSequence =
                ROW_NUMBER() OVER
                (
                    PARTITION BY SourceID, SpecimenID, SectionType
                    ORDER BY RowUpdateDateTime, TextLine
                ),
            TextLine,
            RowUpdateDateTime
        INTO #RawText
        FROM
        (
            SELECT SourceID, SpecimenID, 'FINDINGS' AS SectionType, TextLine, RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimenFindingsText

            UNION ALL

            SELECT SourceID, SpecimenID, 'HISTOLOGY' AS SectionType, TextLine, RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimenHistologyText

            UNION ALL

            SELECT SourceID, SpecimenID, 'ADDENDUM' AS SectionType, TextLine, RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimenAddendumText

            UNION ALL

            SELECT SourceID, SpecimenID, 'COMMENT' AS SectionType, TextLine, RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimenCommentsText
        ) rawText
        WHERE NULLIF(LTRIM(RTRIM(TextLine)), '') IS NOT NULL;

        INSERT INTO dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended
        (
            PatientID,
            VisitID,
            SourceID,
            SpecimenID,
            SectionType,
            SectionText,
            RowUpdateDateTime,
            ExtractedOn
        )
        SELECT
            c.PatientID,
            c.VisitID,
            c.SourceID,
            c.SpecimenID,
            rt.SectionType,

            SectionText =
                STUFF((
                    SELECT CHAR(13) + CHAR(10) + rt2.TextLine
                    FROM #RawText rt2
                    WHERE rt2.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                          c.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
                      AND rt2.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS =
                          c.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS
                      AND rt2.SectionType = rt.SectionType
                    ORDER BY rt2.LineSequence
                    FOR XML PATH(''), TYPE
                ).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),

            RowUpdateDateTime = MAX(rt.RowUpdateDateTime),
            ExtractedOn = SYSDATETIME()
        FROM #Cases c
        INNER JOIN #RawText rt
            ON rt.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               c.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND rt.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS =
               c.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS
        GROUP BY
            c.PatientID,
            c.VisitID,
            c.SourceID,
            c.SpecimenID,
            rt.SectionType;

        INSERT INTO dbo.tbl_FCAP1A_PathologyEHR_Extended
        (
            PatientID,
            VisitID,
            SourceID,
            SpecimenID,
            AccessionNumber,
            NoteDate,
            NoteDateTime,
            NoteType,
            NoteTitle,
            NoteStatus,
            PathologyCaseType,
            PathologyCaseStatus,
            ReceivedDateTime,
            FinalReportDateTime,
            AuthorProviderID,
            AuthorProviderName,
            PathologistUserID,
            PathologyText,
            HasFindingsText,
            HasHistologyText,
            HasAddendumText,
            HasCommentText,
            HasCorrection,
            RecordSource,
            ElementSourceID,
            RowUpdateDateTime,
            ExtractedOn
        )
        SELECT
            c.PatientID,
            c.VisitID,
            c.SourceID,
            c.SpecimenID,
            c.AccessionNumber,

            NoteDate = CAST(c.NoteDateTime AS DATE),
            c.NoteDateTime,

            NoteType = N'Pathology EHR',

            NoteTitle =
                NULLIF(
                    CONCAT(
                        N'Pathology EHR',
                        CASE
                            WHEN c.PathologyCaseType IS NOT NULL
                                THEN N' - ' + c.PathologyCaseType
                            ELSE N''
                        END,
                        CASE
                            WHEN c.AccessionNumber IS NOT NULL
                                THEN N' - ' + c.AccessionNumber
                            ELSE N''
                        END
                    ),
                    N''
                ),

            NoteStatus = c.PathologyCaseStatus,

            c.PathologyCaseType,
            c.PathologyCaseStatus,
            c.ReceivedDateTime,
            c.FinalReportDateTime,

            c.AuthorProviderID,
            c.AuthorProviderName,
            c.PathologistUserID,

            PathologyText =
                LTRIM(RTRIM(
                    CONCAT(
                        CASE
                            WHEN findingsAgg.SectionText IS NOT NULL
                                THEN N'FINDINGS:' + CHAR(13) + CHAR(10) + findingsAgg.SectionText + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
                            ELSE N''
                        END,
                        CASE
                            WHEN histologyAgg.SectionText IS NOT NULL
                                THEN N'HISTOLOGY:' + CHAR(13) + CHAR(10) + histologyAgg.SectionText + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
                            ELSE N''
                        END,
                        CASE
                            WHEN addendumAgg.SectionText IS NOT NULL
                                THEN N'ADDENDUM:' + CHAR(13) + CHAR(10) + addendumAgg.SectionText + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
                            ELSE N''
                        END,
                        CASE
                            WHEN commentAgg.SectionText IS NOT NULL
                                THEN N'COMMENT:' + CHAR(13) + CHAR(10) + commentAgg.SectionText
                            ELSE N''
                        END
                    )
                )),

            HasFindingsText =
                CASE WHEN findingsAgg.SectionText IS NOT NULL THEN 1 ELSE 0 END,

            HasHistologyText =
                CASE WHEN histologyAgg.SectionText IS NOT NULL THEN 1 ELSE 0 END,

            HasAddendumText =
                CASE WHEN addendumAgg.SectionText IS NOT NULL THEN 1 ELSE 0 END,

            HasCommentText =
                CASE WHEN commentAgg.SectionText IS NOT NULL THEN 1 ELSE 0 END,

            HasCorrection =
                CASE WHEN corrAgg.CorrectionCount > 0 THEN 1 ELSE 0 END,

            RecordSource = N'MEDITECH Pathology',

            ElementSourceID =
                CONCAT(c.SourceID, N'|', c.VisitID, N'|', c.SpecimenID),

            RowUpdateDateTime =
                COALESCE(rowDates.MaxRowUpdateDateTime, c.BaseRowUpdateDateTime),

            ExtractedOn = SYSDATETIME()
        FROM #Cases c

        OUTER APPLY
        (
            SELECT SectionText = tb.SectionText
            FROM dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended tb
            WHERE tb.PatientID = c.PatientID
              AND tb.VisitID = c.VisitID
              AND tb.SourceID = c.SourceID
              AND tb.SpecimenID = c.SpecimenID
              AND tb.SectionType = 'FINDINGS'
        ) findingsAgg

        OUTER APPLY
        (
            SELECT SectionText = tb.SectionText
            FROM dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended tb
            WHERE tb.PatientID = c.PatientID
              AND tb.VisitID = c.VisitID
              AND tb.SourceID = c.SourceID
              AND tb.SpecimenID = c.SpecimenID
              AND tb.SectionType = 'HISTOLOGY'
        ) histologyAgg

        OUTER APPLY
        (
            SELECT SectionText = tb.SectionText
            FROM dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended tb
            WHERE tb.PatientID = c.PatientID
              AND tb.VisitID = c.VisitID
              AND tb.SourceID = c.SourceID
              AND tb.SpecimenID = c.SpecimenID
              AND tb.SectionType = 'ADDENDUM'
        ) addendumAgg

        OUTER APPLY
        (
            SELECT SectionText = tb.SectionText
            FROM dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended tb
            WHERE tb.PatientID = c.PatientID
              AND tb.VisitID = c.VisitID
              AND tb.SourceID = c.SourceID
              AND tb.SpecimenID = c.SpecimenID
              AND tb.SectionType = 'COMMENT'
        ) commentAgg

        OUTER APPLY
        (
            SELECT
                CorrectionCount = COUNT_BIG(1),
                CorrectionMaxRowUpdateDateTime = MAX(pc.RowUpdateDateTime)
            FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimenCorrections pc
            WHERE pc.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                  c.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
              AND pc.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS =
                  c.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS
        ) corrAgg

        OUTER APPLY
        (
            SELECT TextMaxRowUpdateDateTime = MAX(tb.RowUpdateDateTime)
            FROM dbo.tbl_FCAP1A_PathologyEHR_TextBlocks_Extended tb
            WHERE tb.PatientID = c.PatientID
              AND tb.VisitID = c.VisitID
              AND tb.SourceID = c.SourceID
              AND tb.SpecimenID = c.SpecimenID
        ) textDates

        OUTER APPLY
        (
            SELECT MaxRowUpdateDateTime = MAX(v.RowUpdateDateTime)
            FROM
            (
                VALUES
                    (c.BaseRowUpdateDateTime),
                    (textDates.TextMaxRowUpdateDateTime),
                    (corrAgg.CorrectionMaxRowUpdateDateTime)
            ) v(RowUpdateDateTime)
        ) rowDates

        WHERE
            findingsAgg.SectionText IS NOT NULL
            OR histologyAgg.SectionText IS NOT NULL
            OR addendumAgg.SectionText IS NOT NULL
            OR commentAgg.SectionText IS NOT NULL;

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_PathologyEHR_Extended;

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
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            N'PathologyEHR_Extended',
            @WindowStart,
            @WindowEnd,
            NULL,
            @RecordCount,
            SYSTEM_USER,
            NULL,
            N'PathologyEHR_Extended rebuild completed. TextBlocks table stores one row per specimen per section with full section text.'
        );

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

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
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            N'PathologyEHR_Extended',
            @WindowStart,
            @WindowEnd,
            NULL,
            NULL,
            SYSTEM_USER,
            @Err,
            N'Error during PathologyEHR_Extended rebuild.'
        );

        THROW;
    END CATCH;

END;
