USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_ProblemList
    Purpose   : Builds a dedicated longitudinal problem-list contract across active, pending, office, and health-concern sources.
    Grain     : one row per problem or health-concern assertion
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_ProblemList]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_ProblemList', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_ProblemList] (
            [ProblemKey] NVARCHAR(180) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [ProblemRecordType] VARCHAR(30) NOT NULL,
            [ProblemInstanceID] NVARCHAR(80) NOT NULL,
            [ProblemCode] NVARCHAR(100) NULL,
            [ProblemDictionaryID] NVARCHAR(100) NULL,
            [ProblemName] NVARCHAR(500) NULL,
            [ProblemDescription] NVARCHAR(1000) NULL,
            [ProblemStatus] NVARCHAR(100) NULL,
            [ProblemCategory] NVARCHAR(100) NULL,
            [Priority] NVARCHAR(60) NULL,
            [OnsetDateTime] DATETIME2(0) NULL,
            [ResolvedDateTime] DATETIME2(0) NULL,
            [EnteredDateTime] DATETIME2(0) NULL,
            [EnteredByUserID] NVARCHAR(100) NULL,
            [Deleted] BIT NOT NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_ProblemList') AND name = N'UX_ProblemList_Key')
        CREATE UNIQUE INDEX [UX_ProblemList_Key] ON dbo.[tbl_FCAP1A_ProblemList] ([ProblemKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_ProblemList') AND name = N'IX_ProblemList_PatientTime')
            CREATE INDEX [IX_ProblemList_PatientTime] ON dbo.[tbl_FCAP1A_ProblemList] ([PatientID], [OnsetDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [ProblemKey] NVARCHAR(180) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [ProblemRecordType] VARCHAR(30) NOT NULL,
            [ProblemInstanceID] NVARCHAR(80) NOT NULL,
            [ProblemCode] NVARCHAR(100) NULL,
            [ProblemDictionaryID] NVARCHAR(100) NULL,
            [ProblemName] NVARCHAR(500) NULL,
            [ProblemDescription] NVARCHAR(1000) NULL,
            [ProblemStatus] NVARCHAR(100) NULL,
            [ProblemCategory] NVARCHAR(100) NULL,
            [Priority] NVARCHAR(60) NULL,
            [OnsetDateTime] DATETIME2(0) NULL,
            [ResolvedDateTime] DATETIME2(0) NULL,
            [EnteredDateTime] DATETIME2(0) NULL,
            [EnteredByUserID] NVARCHAR(100) NULL,
            [Deleted] BIT NOT NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH Problems AS (
            SELECT CONVERT(NVARCHAR(180), CONCAT('ACTIVE|', p.SourceID, '|', p.PatientID, '|', p.ProblemInstanceID)) ProblemKey,
                   p.SourceID, p.PatientID, p.ProblemRegistrationOid_RegAcctID VisitID, CONVERT(VARCHAR(30), 'problem') ProblemRecordType,
                   CONVERT(NVARCHAR(80), p.ProblemInstanceID) ProblemInstanceID, p.ProblemDiagnosisCode_MisDxID ProblemCode,
                   p.ProblemDictionaryOid_MisPatProblemID ProblemDictionaryID,
                   COALESCE(p.ProblemSelectedDescription, d.Name, p.ProblemDisplay) ProblemName, p.ProblemFreeText ProblemDescription,
                   p.ProblemStatus, p.ProblemCategory, p.ProblemPriority Priority,
                   TRY_CONVERT(DATETIME2(0), p.ProblemOnsetDate) OnsetDateTime, p.ProblemDeletedDateTime ResolvedDateTime,
                   p.ProblemInitializedDateTime EnteredDateTime, p.ProblemInitializedBy_UnvUserID EnteredByUserID,
                   CONVERT(BIT, IIF(p.ProblemDeletedDateTime IS NULL, 0, 1)) Deleted,
                   CONVERT(SYSNAME, 'EmrPat_Problems') SourceTable, COALESCE(p.RowUpdateDateTime, pm.RowUpdateDateTime) RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPat_Problems p LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPat_ProblemsMain pm ON pm.SourceID=p.SourceID AND pm.PatientID=p.PatientID INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=p.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].MisPatProblem_Main d ON d.SourceID=p.SourceID AND d.MisPatProblemID=p.ProblemDictionaryOid_MisPatProblemID
        ), Ranked AS (SELECT *, ROW_NUMBER() OVER(PARTITION BY ProblemKey ORDER BY RowUpdateDateTime DESC) rn FROM Problems)
        INSERT #Build ([ProblemKey], [SourceID], [PatientID], [VisitID], [ProblemRecordType], [ProblemInstanceID], [ProblemCode], [ProblemDictionaryID], [ProblemName], [ProblemDescription], [ProblemStatus], [ProblemCategory], [Priority], [OnsetDateTime], [ResolvedDateTime], [EnteredDateTime], [EnteredByUserID], [Deleted], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
        SELECT ProblemKey, SourceID, CONVERT(NVARCHAR(50),PatientID), CONVERT(NVARCHAR(50),VisitID), ProblemRecordType,
               ProblemInstanceID, CONVERT(NVARCHAR(100),ProblemCode), CONVERT(NVARCHAR(100),ProblemDictionaryID),
               CONVERT(NVARCHAR(500),ProblemName), CONVERT(NVARCHAR(1000),ProblemDescription), CONVERT(NVARCHAR(100),ProblemStatus),
               CONVERT(NVARCHAR(100),ProblemCategory), CONVERT(NVARCHAR(60),Priority), OnsetDateTime, ResolvedDateTime, EnteredDateTime,
               CONVERT(NVARCHAR(100),EnteredByUserID), Deleted, SourceTable, CONVERT(DATETIME2(0),RowUpdateDateTime), SYSDATETIME()
        FROM Ranked WHERE rn=1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_ProblemList];
            INSERT INTO dbo.[tbl_FCAP1A_ProblemList] ([ProblemKey], [SourceID], [PatientID], [VisitID], [ProblemRecordType], [ProblemInstanceID], [ProblemCode], [ProblemDictionaryID], [ProblemName], [ProblemDescription], [ProblemStatus], [ProblemCategory], [Priority], [OnsetDateTime], [ResolvedDateTime], [EnteredDateTime], [EnteredByUserID], [Deleted], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
            SELECT [ProblemKey], [SourceID], [PatientID], [VisitID], [ProblemRecordType], [ProblemInstanceID], [ProblemCode], [ProblemDictionaryID], [ProblemName], [ProblemDescription], [ProblemStatus], [ProblemCategory], [Priority], [OnsetDateTime], [ResolvedDateTime], [EnteredDateTime], [EnteredByUserID], [Deleted], [SourceTable], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Problem List',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Problem List',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
