USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_SocialHistory
    Purpose   : Builds social-history responses by resolving configured smoking/social query IDs and the query dictionary.
    Grain     : one row per patient social-history response
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_SocialHistory]
    @WindowStart DATE = '2022-11-05',
    @WindowEnd DATE = '2026-06-14',
    @MinimumPublishRows BIGINT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WindowStart IS NULL OR @WindowEnd IS NULL OR @WindowStart > @WindowEnd
        THROW 51000, 'A valid inclusive extraction window is required.', 1;
    IF @MinimumPublishRows < 1
        THROW 51000, 'MinimumPublishRows must be at least one.', 1;

    DECLARE @RunStart DATETIME2(0) = SYSDATETIME(), @RunEnd DATETIME2(0),
            @RecordCount BIGINT = 0, @TotalEligible BIGINT = 0;

    IF OBJECT_ID(N'dbo.FCAP1A_Cohort_Log', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID INT IDENTITY(1,1) PRIMARY KEY, RunStart DATETIME NOT NULL, RunEnd DATETIME NULL,
            DurationSeconds INT NULL, RunStatus VARCHAR(20) NOT NULL, DataTopic NVARCHAR(100) NOT NULL,
            WindowStart DATE NULL, WindowEnd DATE NULL, TotalEligible INT NULL, RecordCount INT NULL,
            ProcessedBy NVARCHAR(100) DEFAULT SYSTEM_USER, ErrorMessage NVARCHAR(4000) NULL,
            Remarks NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_SocialHistory', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_SocialHistory] (
            [SocialHistoryKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [QueryID] NVARCHAR(100) NOT NULL,
            [Question] NVARCHAR(1000) NULL,
            [Response] NVARCHAR(2000) NULL,
            [ResponseSequence] INT NULL,
            [ResponseScope] VARCHAR(20) NOT NULL,
            [RecordedDateTime] DATETIME2(0) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_SocialHistory') AND name = N'UX_SocialHistory_Key')
        CREATE UNIQUE INDEX [UX_SocialHistory_Key] ON dbo.[tbl_FCAP1A_SocialHistory] ([SocialHistoryKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_SocialHistory') AND name = N'IX_SocialHistory_PatientTime')
            CREATE INDEX [IX_SocialHistory_PatientTime] ON dbo.[tbl_FCAP1A_SocialHistory] ([PatientID], [RecordedDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [SocialHistoryKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [QueryID] NVARCHAR(100) NOT NULL,
            [Question] NVARCHAR(1000) NULL,
            [Response] NVARCHAR(2000) NULL,
            [ResponseSequence] INT NULL,
            [ResponseScope] VARCHAR(20) NOT NULL,
            [RecordedDateTime] DATETIME2(0) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH SocialQueries AS (
            SELECT q.SourceID,q.MisQryID,q.Text,q.Mnemonic FROM [NBIDRSRV2].[AKULiveATdb].[dbo].MisQry_Main q
            WHERE UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%SOCIAL HIST%'
               OR UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%SMOK%'
               OR UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%TOBACCO%'
               OR UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%ALCOHOL%'
            ), Responses AS (
            SELECT CONVERT(NVARCHAR(220),CONCAT('PAT|',r.SourceID,'|',r.PatientID,'|',r.QueryID,'|0')) SocialHistoryKey,
                   r.SourceID,r.PatientID,CONVERT(NVARCHAR(50),NULL) VisitID,r.QueryID,q.Text Question,r.QueryResponse Response,
                   CONVERT(INT,NULL) ResponseSequence,CONVERT(VARCHAR(20),'patient') ResponseScope,r.RowUpdateDateTime RecordedDateTime,
                   CONVERT(SYSNAME,'HimRec_CustomDataQueries_Queries') SourceTable
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].HimRec_CustomDataQueries_Queries r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('PATM|',r.SourceID,'|',r.PatientID,'|',r.QueryID,'|',r.QuerySeqID)),r.SourceID,r.PatientID,NULL,
                   r.QueryID,q.Text,r.QueryResponse,r.QuerySeqID,'patient',r.RowUpdateDateTime,'HimRec_CustomDataQueries_QueriesMult'
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].HimRec_CustomDataQueries_QueriesMult r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('VIS|',r.SourceID,'|',r.VisitID,'|',r.QueryID,'|0')),r.SourceID,a.PatientID,r.VisitID,
                   r.QueryID,q.Text,r.QueryResponse,NULL,'visit',r.RowUpdateDateTime,'RegAcct_CustomDataQueries_Queries'
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_CustomDataQueries_Queries r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main a ON a.SourceID=r.SourceID AND a.VisitID=r.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('VISM|',r.SourceID,'|',r.VisitID,'|',r.QueryID,'|',r.QuerySeqID)),r.SourceID,a.PatientID,r.VisitID,
                   r.QueryID,q.Text,r.QueryResponse,r.QuerySeqID,'visit',r.RowUpdateDateTime,'RegAcct_CustomDataQueries_QueriesMult'
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_CustomDataQueries_QueriesMult r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main a ON a.SourceID=r.SourceID AND a.VisitID=r.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
        ), Ranked AS(SELECT *,ROW_NUMBER() OVER(PARTITION BY SocialHistoryKey ORDER BY RecordedDateTime DESC) rn FROM Responses)
        INSERT #Build ([SocialHistoryKey], [SourceID], [PatientID], [VisitID], [QueryID], [Question], [Response], [ResponseSequence], [ResponseScope], [RecordedDateTime], [SourceTable], [ExtractedOn])
        SELECT SocialHistoryKey,SourceID,CONVERT(NVARCHAR(50),PatientID),CONVERT(NVARCHAR(50),VisitID),CONVERT(NVARCHAR(100),QueryID),
               CONVERT(NVARCHAR(1000),Question),CONVERT(NVARCHAR(2000),Response),ResponseSequence,ResponseScope,
               CONVERT(DATETIME2(0),RecordedDateTime),SourceTable,SYSDATETIME() FROM Ranked WHERE rn=1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_SocialHistory];
            INSERT INTO dbo.[tbl_FCAP1A_SocialHistory] ([SocialHistoryKey], [SourceID], [PatientID], [VisitID], [QueryID], [Question], [Response], [ResponseSequence], [ResponseScope], [RecordedDateTime], [SourceTable], [ExtractedOn])
            SELECT [SocialHistoryKey], [SourceID], [PatientID], [VisitID], [QueryID], [Question], [Response], [ResponseSequence], [ResponseScope], [RecordedDateTime], [SourceTable], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Social History',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             N'Author: test; staged and minimum-row-gated publication.');
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, ErrorMessage, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Social History',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
