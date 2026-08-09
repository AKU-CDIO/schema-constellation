USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_ADT_Extended]    Script Date: 7/13/2026 12:48:39 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure  : usp_Build_FCAP1A_ADT_Extended
    Author     : Allan Z
    QC Date    : 2026-02-19
	Updated		: 2026 -07-13

    Description:
      Builds the FCAP 1A ADT dataset for the cohort, based on AKU Meditech data.
      AKU does not record intra-visit transfer or movement events,
      so ADT consists of:
         1. An ADMIT event from AdmVisits (ServiceDateTime)
         2. A DISCHARGE event from AdmClinDepartureData (DateTime)

      Every event is represented as one row with EventType and EventDateTime.
      All visit-level fields remain unchanged from the original design.
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_ADT_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart        DATETIME = SYSDATETIME(),
        @RunEnd          DATETIME,
        @DurationSeconds INT,
        @RecordCount     INT = 0,
        @WindowStart     DATE = '2022-11-05',
        @WindowEnd       DATE = '2026-06-14',
        @WindowEndNextDay DATE;

    SET @WindowEndNextDay = DATEADD(DAY, 1, @WindowEnd);

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
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
            ProcessedBy     NVARCHAR(100) DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000) NULL,
            Remarks         NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_ADT_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_ADT_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_ADT_Extended (
        ADT_ID INT IDENTITY(1,1) PRIMARY KEY,
        EventType      VARCHAR(20) NOT NULL,
        EventDateTime  DATETIME    NOT NULL,
        VisitID        NVARCHAR(255) NOT NULL,
        PatientID      NVARCHAR(255) NOT NULL,
        SourceID       NVARCHAR(3)   NULL,
        AccountNumber  NVARCHAR(255) NULL,
        ServiceDateTime               DATETIME NULL,
        ObservationDateTime           DATETIME NULL,
        ConditionDateTime             DATETIME NULL,
        LoaEffectiveDateTime          DATETIME NULL,
        LastHospitalBeginDateTime     DATETIME NULL,
        LastHospitalEndDateTime       DATETIME NULL,
        RowUpdateDateTime             DATETIME NULL,
        InpatientOrOutpatient         NVARCHAR(255) NULL,
        InpatientServiceID            NVARCHAR(255) NULL,
        InpatientServiceName          NVARCHAR(255) NULL,
        LocationID                    NVARCHAR(255) NULL,
        RoomID                        NVARCHAR(255) NULL,
        BedID                         NVARCHAR(255) NULL,
        AccommodationID               NVARCHAR(255) NULL,
        RoomRateAccommodation         NVARCHAR(255) NULL,
        FacilityID                    NVARCHAR(255) NULL,
        SpecialProgramID              NVARCHAR(255) NULL,
        EncounterStatus               NVARCHAR(255) NULL,
        ExpectedLengthOfStay          INT           NULL,
        FinancialClassID              NVARCHAR(255) NULL,
        PrimaryInsuranceID            NVARCHAR(255) NULL,
        LastHospital                  NVARCHAR(255) NULL,
        LoaFacilityType               NVARCHAR(255) NULL,
        LoaHoldOrders                 NVARCHAR(255) NULL,
        LoaStatus                     NVARCHAR(255) NULL,
        PriorOutpatientStatus         NVARCHAR(255) NULL,
        ReasonForVisit                NVARCHAR(255) NULL,
        TreatmentAuthorizationNumber  NVARCHAR(255) NULL,
        Deleted                       BIT NULL,
        PartialDelete                 BIT NULL,
        Address1                      NVARCHAR(255) NULL,
        Address2                      NVARCHAR(255) NULL,
        City                          NVARCHAR(255) NULL,
        StateProvince                 NVARCHAR(255) NULL,
        PostalCode                    NVARCHAR(255) NULL,
        HomePhone                     NVARCHAR(255) NULL,
        OtherPhone                    NVARCHAR(255) NULL,
        Email                         NVARCHAR(255) NULL,
        UseEmail                      NVARCHAR(255) NULL,
        Affiliation                   NVARCHAR(255) NULL,
        OutreachNumber                NVARCHAR(255) NULL,
        UniquePublicIdentifier        NVARCHAR(255) NULL,
        DispositionID                 NVARCHAR(255) NULL,
        DepartureDiagnosis            NVARCHAR(255) NULL,
        DepartureComment              NVARCHAR(255) NULL,
        ExtractedOn                   DATETIME NOT NULL DEFAULT SYSDATETIME()
    );

    BEGIN TRY

        INSERT INTO dbo.tbl_FCAP1A_ADT_Extended (
            EventType, EventDateTime,
            VisitID, PatientID, SourceID, AccountNumber,
            ServiceDateTime, ObservationDateTime, ConditionDateTime,
            LoaEffectiveDateTime, LastHospitalBeginDateTime,
            LastHospitalEndDateTime, RowUpdateDateTime,
            InpatientOrOutpatient, InpatientServiceID, InpatientServiceName,
            LocationID, RoomID, BedID, AccommodationID,
            RoomRateAccommodation, FacilityID, SpecialProgramID,
            EncounterStatus,
            ExpectedLengthOfStay, FinancialClassID, PrimaryInsuranceID,
            LastHospital, LoaFacilityType, LoaHoldOrders, LoaStatus,
            PriorOutpatientStatus,
            ReasonForVisit, TreatmentAuthorizationNumber,
            Deleted, PartialDelete,
            Address1, Address2, City, StateProvince, PostalCode,
            HomePhone, OtherPhone, Email, UseEmail,
            Affiliation, OutreachNumber, UniquePublicIdentifier,
            DispositionID, DepartureDiagnosis, DepartureComment,
            ExtractedOn
        )
        SELECT DISTINCT
            'ADMIT',
            v.ServiceDateTime,
            v.VisitID,
            v.PatientID,
            v.SourceID,
            v.AccountNumber,
            v.ServiceDateTime,
            v.ObservationDateTime,
            v.ConditionDateTime,
            v.LoaEffectiveDateTime,
            v.LastHospitalBeginDateTime,
            v.LastHospitalEndDateTime,
            v.RowUpdateDateTime,
            v.InpatientOrOutpatient,
            v.InpatientServiceID,
            v.InpatientServiceName,
            v.LocationID,
            v.RoomID,
            v.BedID,
            v.AccommodationID,
            v.RoomRateAccommodation,
            v.FacilityID,
            v.SpecialProgramID,
            v.Status,
            v.ExpectedLengthOfStay,
            v.FinancialClassID,
            v.PrimaryInsuranceID,
            v.LastHospital,
            v.LoaFacilityType,
            v.LoaHoldOrders,
            v.LoaStatus,
            v.PriorOutpatientStatus,
            v.ReasonForVisit,
            v.TreatmentAuthorizationNumber,
            CASE WHEN v.Deleted = 'Y' THEN 1 WHEN v.Deleted = 'N' THEN 0 ELSE NULL END,
            CASE WHEN v.PartialDelete = 'Y' THEN 1 WHEN v.PartialDelete = 'N' THEN 0 ELSE NULL END,
            v.Address1,
            v.Address2,
            v.City,
            v.StateProvince,
            v.PostalCode,
            v.HomePhone,
            v.OtherPhone,
            v.Email,
            v.UseEmail,
            v.Affiliation,
            v.OutreachNumber,
            v.UniquePublicIdentifier,
            NULL,
            NULL,
            NULL,
            SYSDATETIME()
        FROM dbo.tbl_FCAP1A_Cohort10_Extended c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        WHERE v.ServiceDateTime >= @WindowStart
          AND v.ServiceDateTime < @WindowEndNextDay;

        SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_ADT_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd, RecordCount,
            ProcessedBy, Remarks
        )
        VALUES (
            @RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
            'ADT_Extended', @WindowStart, @WindowEnd, @RecordCount,
            SYSTEM_USER, 'ADT build completed with ADMIT and DISCHARGE events.'
        );

    END TRY
    BEGIN CATCH
        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart, RunEnd, RunStatus, DataTopic,
            WindowStart, WindowEnd, ProcessedBy, ErrorMessage, Remarks
        )
        VALUES (
            @RunStart, SYSDATETIME(), 'FAILED', 'ADT_Extended',
            @WindowStart, @WindowEnd, SYSTEM_USER,
            ERROR_MESSAGE(), 'ADT build failed.'
        );

        THROW;
    END CATCH;
END;