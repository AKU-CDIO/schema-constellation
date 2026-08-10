USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_OtherReports
    Purpose   : Consolidates patient-summary documents and account report references not owned by a more specific domain.
    Grain     : one row per report or document version
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_OtherReports]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_OtherReports', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_OtherReports] (
            [ReportKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [ReportDateTime] DATETIME2(0) NULL,
            [ReportType] NVARCHAR(100) NULL,
            [ReportIdentifier] NVARCHAR(200) NULL,
            [Status] NVARCHAR(100) NULL,
            [SpecialtyID] NVARCHAR(80) NULL,
            [LastValue] NVARCHAR(2000) NULL,
            [Confidential] BIT NULL,
            [ResultReference] NVARCHAR(1000) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_OtherReports') AND name = N'UX_OtherReports_Key')
        CREATE UNIQUE INDEX [UX_OtherReports_Key] ON dbo.[tbl_FCAP1A_OtherReports] ([ReportKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_OtherReports') AND name = N'IX_OtherReports_PatientTime')
            CREATE INDEX [IX_OtherReports_PatientTime] ON dbo.[tbl_FCAP1A_OtherReports] ([PatientID], [ReportDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [ReportKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [ReportDateTime] DATETIME2(0) NULL,
            [ReportType] NVARCHAR(100) NULL,
            [ReportIdentifier] NVARCHAR(200) NULL,
            [Status] NVARCHAR(100) NULL,
            [SpecialtyID] NVARCHAR(80) NULL,
            [LastValue] NVARCHAR(2000) NULL,
            [Confidential] BIT NULL,
            [ResultReference] NVARCHAR(1000) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH Reports AS(
            SELECT CONVERT(NVARCHAR(220),CONCAT('IMG|',i.SourceID,'|',i.VisitID,'|',i.DataUrnID,'|',i.ImageKeyID)),i.SourceID,r.PatientID,i.VisitID,
                   COALESCE(i.ImageDate,i.RowUpdateDateTime),i.ImageInterpretationType,i.ImageIdentifier,i.ImageStatus,NULL,NULL,NULL,i.ImageUrl,
                   'EmrAcctRep_Images',i.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrAcctRep_Images i INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main r ON r.SourceID=i.SourceID AND r.VisitID=i.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            WHERE COALESCE(i.ImageDate,i.RowUpdateDateTime)>=@WindowStart AND COALESCE(i.ImageDate,i.RowUpdateDateTime)<DATEADD(DAY,1,@WindowEnd)
        ),Ranked AS(SELECT *,ROW_NUMBER()OVER(PARTITION BY ReportKey ORDER BY RowUpdateDateTime DESC)rn FROM Reports)
        INSERT #Build ([ReportKey], [SourceID], [PatientID], [VisitID], [ReportDateTime], [ReportType], [ReportIdentifier], [Status], [SpecialtyID], [LastValue], [Confidential], [ResultReference], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
        SELECT ReportKey,SourceID,CONVERT(NVARCHAR(50),PatientID),CONVERT(NVARCHAR(50),VisitID),CONVERT(DATETIME2(0),ReportDateTime),
               CONVERT(NVARCHAR(100),ReportType),CONVERT(NVARCHAR(200),ReportIdentifier),CONVERT(NVARCHAR(100),Status),
               CONVERT(NVARCHAR(80),SpecialtyID),CONVERT(NVARCHAR(2000),LastValue),Confidential,CONVERT(NVARCHAR(1000),ResultReference),
               SourceTable,CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME()FROM Ranked WHERE rn=1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_OtherReports];
            INSERT INTO dbo.[tbl_FCAP1A_OtherReports] ([ReportKey], [SourceID], [PatientID], [VisitID], [ReportDateTime], [ReportType], [ReportIdentifier], [Status], [SpecialtyID], [LastValue], [Confidential], [ResultReference], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
            SELECT [ReportKey], [SourceID], [PatientID], [VisitID], [ReportDateTime], [ReportType], [ReportIdentifier], [Status], [SpecialtyID], [LastValue], [Confidential], [ResultReference], [SourceTable], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Other Clinical Reports',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Other Clinical Reports',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
