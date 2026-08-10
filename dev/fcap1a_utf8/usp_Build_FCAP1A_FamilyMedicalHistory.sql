USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_FamilyMedicalHistory]    Script Date: 8/5/2026 11:59:45 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure : dbo.usp_Build_FCAP1A_FamilyMedicalHistory
    Version          : 0.2
    Author           : Derick Imbati
    Development Date : 2026-08-05

    Purpose:
        Builds the FCAP 1A Family Medical History dataset - medical conditions
        documented against patient family members -> dbo.tbl_FCAP1A_FamilyMedicalHistory

    Design (lean, per PatientProvidedInfo_Extended direction):
        - Carries only identity keys (PatientID, SourceID) plus the family
          history facts. Patient-level demographics (Name, Birthdate, Age,
          Sex, etc.) are NOT repeated here - they are already available in
          dbo.tbl_FCAP1A_Demographics_Extended.
        - Dimension resolution (RelationshipName, ConditionDescription)
          is NOT embedded; raw IDs are retained so they can be resolved via the
          source Mis lookup tables / other SPs.

    Sources:
        EmrPat_FamilyMembers, EmrPat_FamilyProblemMembers, EmrPat_FamilyProblems,
        EmrPat_FamilyMembers_DeceasedComment

    Window:
        2022-11-05 through 2026-06-14 inclusive
*/

CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_FamilyMedicalHistory]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart         DATETIME = SYSDATETIME(),
        @RunEnd           DATETIME,
        @DurationSeconds  INT,
        @RecordCount      INT = 0,
        @TotalEligible    INT = 0,
        @WindowStart      DATE = '2022-11-05',
        @WindowEnd        DATE = '2026-06-14',
        @WindowEndNextDay DATE = DATEADD(DAY, 1, '2026-06-14');

    -- Source tables involved in this build (used to populate SourceTable column)
    DECLARE @SourceTableList NVARCHAR(500) =
        N'EmrPat_FamilyMembers, EmrPat_FamilyProblemMembers, EmrPat_FamilyProblems, EmrPat_FamilyMembers_DeceasedComment, tbl_FCAP1A_Cohort10_Extended';

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log
        (
            LogID            INT IDENTITY(1,1) PRIMARY KEY,
            RunStart         DATETIME NOT NULL,
            RunEnd           DATETIME NULL,
            DurationSeconds  INT NULL,
            RunStatus        VARCHAR(20) NOT NULL,
            DataTopic        NVARCHAR(100) NOT NULL,
            WindowStart      DATE NULL,
            WindowEnd        DATE NULL,
            TotalEligible    INT NULL,
            RecordCount      INT NULL,
            ProcessedBy      NVARCHAR(100) NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage     NVARCHAR(4000) NULL,
            Remarks          NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_FamilyMedicalHistory','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_FamilyMedicalHistory;

    CREATE TABLE dbo.tbl_FCAP1A_FamilyMedicalHistory
    (
        FamilyHistoryRowID     BIGINT IDENTITY(1,1) PRIMARY KEY,

        PatientID              NVARCHAR(50) NOT NULL,
        SourceID               VARCHAR(3) NOT NULL,

        FamilyMemberID         NVARCHAR(159) NULL,
        FamilyMemberName       NVARCHAR(75) NULL,

        RelationshipID         NVARCHAR(30) NULL,

        ConditionID            NVARCHAR(48) NULL,

        AgeAtOnset             NVARCHAR(100) NULL,
        ConditionStatus        NVARCHAR(50) NULL,

        FirstRecordedDateTime  DATETIME NULL,
        LastRecordedDateTime   DATETIME NULL,
        RecordedDateTime       DATETIME NULL,

        DeceasedFlag           NVARCHAR(3) NULL,
        DeceasedComment        NVARCHAR(MAX) NULL,

        ProblemNoted           NVARCHAR(3) NULL,
        FamilyProblemFreeText  NVARCHAR(3) NULL,

        RowUpdateDateTime      DATETIME NULL,
        SourceTable            NVARCHAR(500) NOT NULL,
        ExecutionOn            DATETIME NOT NULL
    );

    BEGIN TRY

        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH MemberComments AS
        (
            SELECT
                PatientID,
                SourceID,
                MemberNumberID,
                STRING_AGG(CAST(TextLine AS NVARCHAR(MAX)), CHAR(10))
                    WITHIN GROUP (ORDER BY TextSeqID) AS DeceasedComment,
                MAX(RowUpdateDateTime) AS CommentRowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPat_FamilyMembers_DeceasedComment]
            WHERE TextLine IS NOT NULL
              AND LTRIM(RTRIM(TextLine)) <> ''
              AND UPPER(LTRIM(RTRIM(TextLine))) <> 'NULL'
            GROUP BY
                PatientID,
                SourceID,
                MemberNumberID
        ),

        FamilyHistory AS
        (
            SELECT
                c.PatientID,

                fm.SourceID,
                fm.MemberNumberID AS FamilyMemberID,
                fm.Name AS FamilyMemberName,

                fm.Relationship_MisRelatID AS RelationshipID,

                fp.FamilyProblemCodeID AS ConditionID,

                CAST(NULL AS NVARCHAR(100)) AS AgeAtOnset,
                fp.FamilyProblemState AS ConditionStatus,

                fp.FamilyProblemFirstRecordedDate AS FirstRecordedDateTime,
                fp.FamilyProblemLastRecordedDate AS LastRecordedDateTime,

                COALESCE(
                    fp.FamilyProblemFirstRecordedDate,
                    fp.FamilyProblemLastRecordedDate,
                    fp.RowUpdateDateTime,
                    fm.RowUpdateDateTime
                ) AS RecordedDateTime,

                fm.DeceasedFlag,
                mc.DeceasedComment,

                fm.ProblemNoted,
                fp.FamilyProblemFreeText,

                COALESCE(
                    mc.CommentRowUpdateDateTime,
                    fp.RowUpdateDateTime,
                    fpm.RowUpdateDateTime,
                    fm.RowUpdateDateTime
                ) AS RowUpdateDateTime,

                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        c.PatientID,
                        fm.SourceID,
                        fm.MemberNumberID,
                        fp.FamilyProblemCodeID
                    ORDER BY
                        COALESCE(fp.RowUpdateDateTime, fpm.RowUpdateDateTime, fm.RowUpdateDateTime) DESC
                ) AS rn

            FROM dbo.tbl_FCAP1A_Cohort10_Extended c

            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPat_FamilyMembers] fm
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   fm.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS

            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPat_FamilyProblemMembers] fpm
                ON fm.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   fpm.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND fm.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   fpm.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND fm.MemberNumberID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   fpm.FamilyProblemMemberID COLLATE SQL_Latin1_General_CP1_CI_AS

            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].[EmrPat_FamilyProblems] fp
                ON fpm.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   fp.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND fpm.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   fp.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND fpm.FamilyProblemCodeID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   fp.FamilyProblemCodeID COLLATE SQL_Latin1_General_CP1_CI_AS

            LEFT JOIN MemberComments mc
                ON fm.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   mc.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND fm.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   mc.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
               AND fm.MemberNumberID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   mc.MemberNumberID COLLATE SQL_Latin1_General_CP1_CI_AS

            WHERE COALESCE(
                    fp.FamilyProblemFirstRecordedDate,
                    fp.FamilyProblemLastRecordedDate,
                    fp.RowUpdateDateTime,
                    fm.RowUpdateDateTime
                  ) >= @WindowStart
              AND COALESCE(
                    fp.FamilyProblemFirstRecordedDate,
                    fp.FamilyProblemLastRecordedDate,
                    fp.RowUpdateDateTime,
                    fm.RowUpdateDateTime
                  ) < @WindowEndNextDay
        )

        INSERT INTO dbo.tbl_FCAP1A_FamilyMedicalHistory
        (
            PatientID,
            SourceID,
            FamilyMemberID,
            FamilyMemberName,
            RelationshipID,
            ConditionID,
            AgeAtOnset,
            ConditionStatus,
            FirstRecordedDateTime,
            LastRecordedDateTime,
            RecordedDateTime,
            DeceasedFlag,
            DeceasedComment,
            ProblemNoted,
            FamilyProblemFreeText,
            RowUpdateDateTime,
            SourceTable,
            ExecutionOn
        )
        SELECT
            PatientID,
            SourceID,
            FamilyMemberID,
            FamilyMemberName,
            RelationshipID,
            ConditionID,
            AgeAtOnset,
            ConditionStatus,
            FirstRecordedDateTime,
            LastRecordedDateTime,
            RecordedDateTime,
            DeceasedFlag,
            DeceasedComment,
            ProblemNoted,
            FamilyProblemFreeText,
            RowUpdateDateTime,
            @SourceTableList AS SourceTable,
            @RunStart        AS ExecutionOn
        FROM FamilyHistory
        WHERE rn = 1
          AND (
                ConditionID IS NOT NULL
             OR RelationshipID IS NOT NULL
             OR FamilyMemberID IS NOT NULL
          );

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_FamilyMedicalHistory_Patient
            ON dbo.tbl_FCAP1A_FamilyMedicalHistory (PatientID);

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_FamilyMedicalHistory_Condition
            ON dbo.tbl_FCAP1A_FamilyMedicalHistory (ConditionID);

        CREATE NONCLUSTERED INDEX IX_tbl_FCAP1A_FamilyMedicalHistory_Relationship
            ON dbo.tbl_FCAP1A_FamilyMedicalHistory (RelationshipID);

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_FamilyMedicalHistory;

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
            'FamilyMedicalHistory',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            @RecordCount,
            SYSTEM_USER,
            'Family medical history build completed. Lean fact table: keys + facts only; demographics in Demographics_Extended; dim resolution via Mis lookup tables.'
        );

        PRINT 'FamilyMedicalHistory complete. Rows: ' + CAST(@RecordCount AS VARCHAR(20));

    END TRY
    BEGIN CATCH

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            SYSDATETIME(),
            'FAILED',
            'FamilyMedicalHistory',
            @WindowStart,
            @WindowEnd,
            @TotalEligible,
            SYSTEM_USER,
            ERROR_MESSAGE(),
            'Family medical history build failed.'
        );

        THROW;

    END CATCH;
END;
GO
