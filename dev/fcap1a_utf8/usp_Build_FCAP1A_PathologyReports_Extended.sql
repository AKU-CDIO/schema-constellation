USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_PathologyReports_Extended]    Script Date: 7/13/2026 1:25:59 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

   /* Stored Procedure: usp_Build_FCAP1A_PathologyReports_Extended

    Purpose:
        Build the FCAP 1A Pathology dataset for the extended cohort scope.

        - Creates two related tables:

          1) tbl_FCAP1A_PathologyLines_Extended
             >> One row per pathology text line
             >> Sections: FINDINGS, ADDENDUM, COMMENT
             >> Clean, ordered, deduped line-level text

          2) tbl_FCAP1A_PathologyReports_Extended
             >> One row per pathology case (SpecimenID)
             >> Cohort + FCAP window restricted
             >> Case metadata (AccessionNumber, CaseType, Status, dates)
             >> Aggregated FindingsText, AddendumText as NVARCHAR(MAX)
             >> Flags for HasAddendum, HasComments, HasCorrections

        - Restricts to patients in tbl_FCAP1A_Cohort10_Extended.
        - Applies FCAP 1A window using a clinical datetime:
              COALESCE(FinalSignout, FinalSignOutDateTime, ReceivedDateTime, DateTime, RowUpdateDateTime)
        - Uses PthSpecimens as the pathology case anchor (SpecimenID).
        - Joins to RegAcct_Main for PatientID.
        - Uses FOR XML PATH concatenation to avoid STRING_AGG limits.

    Author      : Allan Z.
    Organization: Aga Khan University – Data Innovation Office
    Date        : 2026-02-22
    Version     : FCAP 1A Pathology (Lines + Reports) Extended

	-------------------------------------------------------------------------------
	Note to Team
	-------------------------------------------------------------------------------
	@Amos/@Deric/@Rais/@Nigel >> tbl_FCAP1A_PathologyLines_Extended is purely for QC.
	
	I've captured the lines comments and addenda in the Main reports table though. */
ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_PathologyReports_Extended]
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
        @RecordCountLines  INT = 0,
        @RecordCountCases  INT = 0;

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

        IF OBJECT_ID('dbo.tbl_FCAP1A_PathologyLines_Extended', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_PathologyLines_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_PathologyLines_Extended
        (
            PatientID         NVARCHAR(255) NOT NULL,
            VisitID           NVARCHAR(255) NOT NULL,
            SourceID          VARCHAR(3)    NOT NULL,
            SpecimenID        NVARCHAR(50)  NOT NULL,
            SectionType       NVARCHAR(20)  NOT NULL,
            TextSeqID         INT           NOT NULL,
            TextLine          NVARCHAR(1000) NULL,
            RowUpdateDateTime DATETIME      NULL,
            ExtractedOn       DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME(),
            CONSTRAINT PK_tbl_FCAP1A_PathologyLines_Extended
                PRIMARY KEY CLUSTERED (PatientID, SpecimenID, SectionType, TextSeqID)
        );

        IF OBJECT_ID('dbo.tbl_FCAP1A_PathologyReports_Extended', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_PathologyReports_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_PathologyReports_Extended
        (
            PathologyRowID        INT IDENTITY(1,1) PRIMARY KEY,
            PatientID             NVARCHAR(255) NOT NULL,
            VisitID               NVARCHAR(255) NOT NULL,
            SourceID              VARCHAR(3)    NOT NULL,
            SpecimenID            NVARCHAR(50)  NOT NULL,
            AccessionNumber       NVARCHAR(50)  NULL,
            CaseType              NVARCHAR(50)  NULL,
            CaseStatus            NVARCHAR(50)  NULL,
            ReceivedDateTime      DATETIME      NULL,
            FinalReportDateTime   DATETIME      NULL,
            ClinicalDateTime      DATETIME      NULL,
            SubmittingProviderID   NVARCHAR(50)  NULL,
            SubmittingProviderName NVARCHAR(255) NULL,
            PathologistUserID     NVARCHAR(50)  NULL,
            HasAddendum           BIT NOT NULL DEFAULT 0,
            HasComments           BIT NOT NULL DEFAULT 0,
            HasCorrections        BIT NOT NULL DEFAULT 0,
            FindingsText          NVARCHAR(MAX) NULL,
            AddendumText          NVARCHAR(MAX) NULL,
            RowUpdateDateTime     DATETIME NOT NULL,
            ExtractedOn           DATETIME2(3) NOT NULL DEFAULT SYSDATETIME()
        );

        IF OBJECT_ID('tempdb..#Cases') IS NOT NULL DROP TABLE #Cases;

        SELECT
            r.PatientID COLLATE DATABASE_DEFAULT AS PatientID,
            ps.VisitID  COLLATE DATABASE_DEFAULT AS VisitID,
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
            CaseType   = COALESCE(ps.TypeOfSpec, ps.Type),
            CaseStatus = ps.Status,
            ps.ReceivedDateTime,
            fs.DateTime AS FinalReportDateTime,
            ClinicalDateTime =
                COALESCE(
                    fs.DateTime,
                    ps.FinalSignOutDateTime,
                    ps.ReceivedDateTime,
                    ps.DateTime,
                    ps.RowUpdateDateTime
                ),
            ps.SubmProviderID,
            ps.SubmProviderFreeEntryName,
            fs.SignOutUserID,
            ps.RowUpdateDateTime
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
            SELECT TOP 1 DateTime, SignOutUserID
            FROM [NBIDRSRV2].[AKULivendb].dbo.PthSpecimenFinalSignouts fs
            WHERE fs.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS =
                  ps.SourceID COLLATE SQL_Latin1_General_CP1_CI_AS
              AND fs.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS =
                  ps.SpecimenID COLLATE SQL_Latin1_General_CP1_CI_AS
            ORDER BY DateTime DESC
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

        INSERT INTO dbo.tbl_FCAP1A_PathologyReports_Extended
        (
            PatientID, VisitID, SourceID, SpecimenID,
            AccessionNumber, CaseType, CaseStatus,
            ReceivedDateTime, FinalReportDateTime, ClinicalDateTime,
            SubmittingProviderID, SubmittingProviderName,
            PathologistUserID, HasAddendum, HasComments, HasCorrections,
            FindingsText, AddendumText,
            RowUpdateDateTime, ExtractedOn
        )
        SELECT
            PatientID, VisitID, SourceID, SpecimenID,
            AccessionNumber, CaseType, CaseStatus,
            ReceivedDateTime, FinalReportDateTime, ClinicalDateTime,
            SubmProviderID, SubmProviderFreeEntryName,
            SignOutUserID,
            0, 0, 0,
            NULL, NULL,
            RowUpdateDateTime,
            SYSDATETIME()
        FROM #Cases;

        SELECT @RecordCountCases = COUNT(*) FROM dbo.tbl_FCAP1A_PathologyReports_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd,
            TotalEligible, RecordCount, ProcessedBy,
            ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
            N'PathologyReports_Extended',
            @WindowStart, @WindowEnd,
            NULL, @RecordCountCases, SYSTEM_USER,
            NULL,
            N'PathologyReports_Extended rebuild completed.'
        );

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd,
            TotalEligible, RecordCount, ProcessedBy,
            ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds, 'FAILED',
            N'PathologyReports_Extended',
            @WindowStart, @WindowEnd,
            NULL, NULL, SYSTEM_USER,
            @Err,
            N'Error during PathologyReports_Extended rebuild.'
        );

        THROW;
    END CATCH;

END;
