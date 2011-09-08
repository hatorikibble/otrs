# --
# Kernel/System/DynamicField.pm - DynamicFields configuration backend
# Copyright (C) 2001-2011 OTRS AG, http://otrs.org/
# --
# $Id: DynamicField.pm,v 1.41 2011-09-08 16:37:49 cr Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::DynamicField;

use strict;
use warnings;

use YAML;
use Kernel::System::Valid;
use Kernel::System::VariableCheck qw(:all);
use Kernel::System::Cache;
use Kernel::System::DynamicField::Backend;

use vars qw($VERSION);
$VERSION = qw($Revision: 1.41 $) [1];

=head1 NAME

Kernel::System::DynamicField

=head1 SYNOPSIS

DynamicFields backend

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create a DynamicField object

    use Kernel::Config;
    use Kernel::System::Encode;
    use Kernel::System::Log;
    use Kernel::System::Main;
    use Kernel::System::DB;
    use Kernel::System::DynamicField;

    my $ConfigObject = Kernel::Config->new();
    my $EncodeObject = Kernel::System::Encode->new(
        ConfigObject => $ConfigObject,
    );
    my $LogObject = Kernel::System::Log->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
    );
    my $MainObject = Kernel::System::Main->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
    );
    my $DBObject = Kernel::System::DB->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
        MainObject   => $MainObject,
    );
    my $DynamicFieldObject = Kernel::System::DynamicField->new(
        ConfigObject        => $ConfigObject,
        EncodeObject        => $EncodeObject,
        LogObject           => $LogObject,
        MainObject          => $MainObject,
        DBObject            => $DBObject,
    );

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # get needed objects
    for my $Needed (qw(ConfigObject EncodeObject LogObject MainObject DBObject)) {
        die "Got no $Needed!" if !$Param{$Needed};

        $Self->{$Needed} = $Param{$Needed};
    }

    # create additional objects
    $Self->{CacheObject} = Kernel::System::Cache->new( %{$Self} );
    $Self->{ValidObject} = Kernel::System::Valid->new( %{$Self} );

    # get the cache TTL (in seconds)
    $Self->{CacheTTL}
        = int( $Self->{ConfigObject}->Get('DynamicField::CacheTTL') || 3600 );

    return $Self;
}

=item DynamicFieldAdd()

add new Dynamic Field config

returns id of new Dynamic field if successful or undef otherwise

    my $ID = $DynamicFieldObject->DynamicFieldAdd(
        Name        => 'NameForField',  # mandatory
        Label       => 'a description', # mandatory, label to show
        FieldOrder  => 123,             # mandatory, display order
        FieldType   => 'Text',          # mandatory, selects the DF backend to use for this field
        ObjectType  => 'Article',       # this controls which object the dynamic field links to
                                        # allow only lowercase letters
        Config      => $ConfigHashRef,  # it is stored on YAML format
                                        # to individual articles, otherwise to tickets
        Reorder     => 1,               # or 0, to trigger reorder function, default 1
        ValidID     => 1,
        UserID      => 123,
    );

Returns:

    $ID = 567;

=cut

sub DynamicFieldAdd {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Key (qw(Name Label FieldOrder FieldType ObjectType Config ValidID UserID)) {
        if ( !$Param{$Key} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $Key!" );
            return;
        }
    }

    # check needed structure for some fields
    if ( $Param{Name} !~ m{ \A [a-z|A-Z|\d]+ \z }xms ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Not valid letters on Name:$Param{Name}!"
        );
        return;
    }

    my $NameExists;

    # check is Name already exists
    return if !$Self->{DBObject}->Prepare(
        SQL   => 'SELECT id FROM dynamic_field WHERE LOWER(name) = LOWER(?)',
        Bind  => [ \$Param{Name} ],
        LIMIT => 1,
    );

    while ( my @Data = $Self->{DBObject}->FetchrowArray() ) {
        $NameExists = 1;
    }

    if ($NameExists) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "The name $Param{Name} already exists for a dynamic field!"
        );
        return;
    }

    if ( $Param{FieldOrder} !~ m{ \A [\d]+ \z }xms ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Not valid number on FieldOrder:$Param{FieldOrder}!"
        );
        return;
    }

    # dump config as string
    my $Config = YAML::Dump( $Param{Config} );

    # sql
    return if !$Self->{DBObject}->Do(
        SQL =>
            'INSERT INTO dynamic_field (name, label, field_Order, field_type, object_type,' .
            'config, valid_id, create_time, create_by, change_time, change_by)' .
            ' VALUES (?, ?, ?, ?, ?, ?, ?, current_timestamp, ?, current_timestamp, ?)',
        Bind => [
            \$Param{Name}, \$Param{Label}, \$Param{FieldOrder}, \$Param{FieldType},
            \$Param{ObjectType}, \$Config, \$Param{ValidID}, \$Param{UserID}, \$Param{UserID},
        ],
    );

    my $DynamicField = $Self->DynamicFieldGet(
        Name => $Param{Name},
    );

    # return ; if no $DynamicField->{ID}
    return if !$DynamicField->{ID};

    # delete cache
    $Self->{CacheObject}->CleanUp(
        Type => 'DynamicField',
    );

    if ( !exists $Param{Reorder} || $Param{Reorder} ) {

        # re-order field list
        $Self->_DynamicFieldReorder(
            ID         => $DynamicField->{ID},
            FieldOrder => $DynamicField->{FieldOrder},
            Mode       => 'Add',
        );
    }

    return $DynamicField->{ID};
}

=item DynamicFieldGet()

get Dynamic Field attributes

    my $DynamicField = $DynamicFieldObject->DynamicFieldGet(
        ID   => 123,             # ID or Name must be provided
        Name => 'DynamicField',
    );

Returns:

    $DynamicField = {
        ID          => 123,
        Name        => 'NameForField',
        Label       => 'The label to show',
        FieldOrder  => 123,
        FieldType   => 'Text',
        ObjectType  => 'Article',
        Config      => $ConfigHashRef,
        ValidID     => 1,
        CreateTime  => '2011-02-08 15:08:00',
        ChangeTime  => '2011-06-11 17:22:00',
    };

=cut

sub DynamicFieldGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ID} && !$Param{Name} ) {
        $Self->{LogObject}->Log( Priority => 'error', Message => 'Need ID or Name!' );
        return;
    }

    # check cache
    my $CacheKey;

    if ( $Param{ID} ) {
        $CacheKey = 'DynamicFieldGet::ID::' . $Param{ID};
    }
    else {
        $CacheKey = 'DynamicFieldGet::Name::' . $Param{Name};

    }
    my $Cache = $Self->{CacheObject}->Get(
        Type => 'DynamicField',
        Key  => $CacheKey,
    );

    # get data from cache
    if ($Cache) {
        return $Cache;
    }

    my %Data;

    # sql
    if ( $Param{ID} ) {
        return if !$Self->{DBObject}->Prepare(
            SQL =>
                'SELECT id, name, label, field_order, field_type, object_type, config,' .
                ' valid_id, create_time, change_time ' .
                'FROM dynamic_field WHERE id = ?',
            Bind => [ \$Param{ID} ],
        );
    }
    else {
        return if !$Self->{DBObject}->Prepare(
            SQL =>
                'SELECT id, name, label, field_order, field_type, object_type, config,' .
                ' valid_id, create_time, change_time ' .
                'FROM dynamic_field WHERE name = ?',
            Bind => [ \$Param{Name} ],
        );
    }

    while ( my @Data = $Self->{DBObject}->FetchrowArray() ) {
        my $Config = YAML::Load( $Data[6] ) || {};

        %Data = (
            ID         => $Data[0],
            Name       => $Data[1],
            Label      => $Data[2],
            FieldOrder => $Data[3],
            FieldType  => $Data[4],
            ObjectType => $Data[5],
            Config     => $Config,
            ValidID    => $Data[7],
            CreateTime => $Data[8],
            ChangeTime => $Data[9],
        );
    }

    # set cache
    $Self->{CacheObject}->Set(
        Type  => 'DynamicField',
        Key   => $CacheKey,
        Value => \%Data,
        TTL   => $Self->{CacheTTL},
    );

    return \%Data;
}

=item DynamicFieldUpdate()

update Dynamic Field content into database

returns 1 on success or undef on error

    my $Success = $DynamicFieldObject->DynamicFieldUpdate(
        ID          => 1234,            # mandatory
        Name        => 'NameForField',  # mandatory
        Label       => 'a description', # mandatory, label to show
        FieldOrder  => 123,             # mandatory, display order
        FieldType   => 'Text',          # mandatory, selects the DF backend to use for this field
        ObjectType  => 'Article',       # this controls which object the dynamic field links to
                                        # allow only lowercase letters
        Config      => $ConfigHashRef,  # it is stored on YAML format
                                        # to individual articles, otherwise to tickets
        ValidID     => 1,
        Reorder     => 1,               # or 0, to trigger reorder function, default 1
        UserID      => 123,
    );

=cut

sub DynamicFieldUpdate {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Key (qw(ID Name Label FieldOrder FieldType ObjectType Config ValidID UserID)) {
        if ( !$Param{$Key} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $Key!" );
            return;
        }
    }

    my $Reorder;
    if ( !exists $Param{Reorder} or $Param{Reorder} eq 1 ) {
        $Reorder = 1;
    }

    # dump config as string
    my $Config = YAML::Dump( $Param{Config} );

    # check needed structure for some fields
    if ( $Param{Name} !~ m{ \A [a-z|A-Z|\d]+ \z }xms ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Not valid letters on Name:$Param{Name} or ObjectType:$Param{ObjectType}!"
        );
        return;
    }

    # check is Name already exists
    my $DynamicFieldDuplicated = $Self->DynamicFieldList(
        ResultType => 'HASH',
    );
    my %DuplicatedFields = reverse %{$DynamicFieldDuplicated};
    %DuplicatedFields = map { $_ => lc $DuplicatedFields{$_} } keys %DuplicatedFields;

    if (
        defined $DuplicatedFields{ lc( $Param{Name} ) } &&
        $DuplicatedFields{ lc( $Param{Name} ) } ne $Param{ID}
        )
    {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "The name $Param{Name} already exists for a dynamic field!"
        );
        return;
    }

    if ( $Param{FieldOrder} !~ m{ \A [\d]+ \z }xms ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Not valid number on FieldOrder:$Param{FieldOrder}!"
        );
        return;
    }

    # get the old dynamic field data
    my $DynamicField = $Self->DynamicFieldGet(
        ID => $Param{ID},
    );

    my $ChangedOrder;

    # check if FieldOrder is changed
    if ( $DynamicField->{FieldOrder} ne $Param{FieldOrder} ) {
        $ChangedOrder = 1;
    }

    # sql
    return if !$Self->{DBObject}->Do(
        SQL => 'UPDATE dynamic_field SET name = ?, label = ?, field_order =?, field_type = ?, '
            . 'object_type = ?, config = ?, valid_id = ?, change_time = current_timestamp, '
            . ' change_by = ? WHERE id = ?',
        Bind => [
            \$Param{Name}, \$Param{Label}, \$Param{FieldOrder}, \$Param{FieldType},
            \$Param{ObjectType}, \$Config, \$Param{ValidID}, \$Param{UserID}, \$Param{ID},
        ],
    );

    # delete cache
    $Self->{CacheObject}->CleanUp(
        Type => 'DynamicField',
    );

    # re-order field list if a change in the order was made
    if ( $Reorder && $ChangedOrder ) {
        my $Success = $Self->_DynamicFieldReorder(
            ID            => $Param{ID},
            FieldOrder    => $Param{FieldOrder},
            Mode          => 'Update',
            OldFieldOrder => $DynamicField->{FieldOrder},
        );
    }
    return 1;
}

=item DynamicFieldDelete()

delete a Dynamic field entry

returns 1 if successful or undef otherwise

    my $Success = $DynamicFieldObject->DynamicFieldDelete(
        ID      => 123,
        UserID  => 123,
        Reorder => 1,               # or 0, to trigger reorder function, default 1
    );

=cut

sub DynamicFieldDelete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Key (qw(ID UserID)) {
        if ( !$Param{$Key} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => "Need $Key!" );
            return;
        }
    }

    # check if exists
    my $DynamicField = $Self->DynamicFieldGet(
        ID => $Param{ID},
    );
    return if !IsHashRefWithData($DynamicField);

    # re-order before delete
    if ( !exists $Param{Reorder} || $Param{Reorder} ) {
        my $Success = $Self->_DynamicFieldReorder(
            ID         => $DynamicField->{ID},
            FieldOrder => $DynamicField->{FieldOrder},
            Mode       => 'Delete',
        );
    }

    # delete dynamic field values
    return if !$Self->{DBObject}->Do(
        SQL  => 'DELETE FROM dynamic_field_value WHERE field_id = ?',
        Bind => [ \$Param{ID} ],
    );

    # delete Dynamic field
    return if !$Self->{DBObject}->Do(
        SQL  => 'DELETE FROM dynamic_field WHERE id = ?',
        Bind => [ \$Param{ID} ],
    );

    # delete cache
    $Self->{CacheObject}->CleanUp(
        Type => 'DynamicField',
    );

    return 1;
}

=item DynamicFieldList()

get DynamicField list ordered by the the "Field Order" field in the DB

    my $List = $DynamicFieldObject->DynamicFieldList();

    or

    my $List = $DynamicFieldObject->DynamicFieldList(
        Valid => 0,             # optional, defaults to 1
        ObjectType => 'Ticket', # optional, any DynamicFields registered object e.g. Article
        ResultType => 'HASH',   # optional, 'ARRAY' or 'HASH', defaults to 'ARRAY'
    );

Returns:

    $List = {
        1 => 'ItemOne',
        2 => 'ItemTwo',
        3 => 'ItemThree',
        4 => 'ItemFour',
    };

    or

    $List = (
        1,
        2,
        3,
        4
    );

=cut

sub DynamicFieldList {
    my ( $Self, %Param ) = @_;

    # check cache
    my $Valid = 1;
    if ( defined $Param{Valid} && $Param{Valid} eq '0' ) {
        $Valid = 0;
    }

    my $ObjectType = $Param{ObjectType} || 'All';

    my $CacheKey = 'DynamicFieldList::Valid::' . $Valid . '::ObjectType::' . $ObjectType;
    my $Cache    = $Self->{CacheObject}->Get(
        Type => 'DynamicField',
        Key  => $CacheKey,
    );

    my $ResultType = $Param{ResultType} || '';
    $ResultType = ( $ResultType eq 'HASH' ? $ResultType : 'ARRAY' );

    if ( $Cache && $Cache eq $ResultType ) {

        # get data from cache
        return $Cache;
    }

    my $SQL = 'SELECT id, name, field_order FROM dynamic_field';

    if ($Valid) {
        $SQL .= ' WHERE valid_id IN (' . join ', ', $Self->{ValidObject}->ValidIDsGet() . ')';

        if ( $Param{ObjectType} && $Param{ObjectType} ne 'All' ) {
            $SQL .= " AND object_type = '" . $Self->{DBObject}->Quote( $Param{ObjectType} ) . "'";
        }
    }
    else {
        if ( $Param{ObjectType} && $Param{ObjectType} ne 'All' ) {
            $SQL .= " WHERE object_type = '" . $Self->{DBObject}->Quote( $Param{ObjectType} ) . "'";
        }
    }

    $SQL .= " ORDER BY field_order, id";

    return if !$Self->{DBObject}->Prepare( SQL => $SQL );

    if ( $ResultType eq 'HASH' ) {
        my %Data;

        while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
            $Data{ $Row[0] } = $Row[1];
        }

        if (%Data) {

            # set cache
            $Self->{CacheObject}->Set(
                Type  => 'DynamicField',
                Key   => $CacheKey,
                Value => \%Data,
                TTL   => $Self->{CacheTTL},
            );
        }

        return \%Data;

    }
    else {

        my @Data;
        while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
            push @Data, $Row[0];
        }

        if (@Data) {

            # set cache
            $Self->{CacheObject}->Set(
                Type  => 'DynamicField',
                Key   => $CacheKey,
                Value => \@Data,
                TTL   => $Self->{CacheTTL},
            );
        }

        return \@Data;
    }

    return;
}

=item DynamicFieldListGet()

get DynamicField list with complete data ordered by the "Field Order" field in the DB

    my $List = $DynamicFieldObject->DynamicFieldListGet();

    or

    my $List = $DynamicFieldObject->DynamicFieldListGet(
        Valid        => 0,            # optional, defaults to 1
        ObjectType   => 'Ticket',     # optional, any DynamicFields registered object e.g. Article
    );

Returns:

    $List = (
        {
            ID          => 123,
            Name        => 'nameforfield',
            Label       => 'The label to show',
            FieldType   => 'Text',
            ObjectType  => 'Article',
            Config      => $ConfigHashRef,
            ValidID     => 1,
            CreateTime  => '2011-02-08 15:08:00',
            ChangeTime  => '2011-06-11 17:22:00',
        },
        {
            ID          => 321,
            Name        => 'fieldname',
            Label       => 'It is not a label',
            FieldType   => 'Text',
            ObjectType  => 'Ticket',
            Config      => $ConfigHashRef,
            ValidID     => 1,
            CreateTime  => '2010-09-11 10:08:00',
            ChangeTime  => '2011-01-01 01:01:01',
        },
        ...
    );

=cut

sub DynamicFieldListGet {
    my ( $Self, %Param ) = @_;

    # check cache
    my $Valid = 1;
    if ( defined $Param{Valid} && $Param{Valid} eq '0' ) {
        $Valid = 0;
    }

    my $ObjectType = $Param{ObjectType} || 'All';

    my $CacheKey = 'DynamicFieldListGet::Valid::' . $Valid . '::ObjectType::' . $ObjectType;
    my $Cache    = $Self->{CacheObject}->Get(
        Type => 'DynamicField',
        Key  => $CacheKey,
    );

    if ($Cache) {

        # get data from cache
        return $Cache;
    }

    my @Data;
    my $SQL = 'SELECT id, name, field_order FROM dynamic_field';

    if ($Valid) {
        $SQL .= ' WHERE valid_id IN (' . join ', ', $Self->{ValidObject}->ValidIDsGet() . ')';

        if ( $Param{ObjectType} && $Param{ObjectType} ne 'All' ) {
            $SQL .= " AND object_type = '" . $Self->{DBObject}->Quote( $Param{ObjectType} ) . "'";
        }
    }
    else {
        if ( $Param{ObjectType} && $Param{ObjectType} ne 'All' ) {
            $SQL .= " WHERE object_type = '" . $Self->{DBObject}->Quote( $Param{ObjectType} ) . "'";
        }
    }

    $SQL .= " ORDER BY field_order, id";

    return if !$Self->{DBObject}->Prepare( SQL => $SQL );

    my @DynamicFieldIDs;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        push @DynamicFieldIDs, $Row[0];
    }

    for my $ItemID (@DynamicFieldIDs) {

        my $DynamicField = $Self->DynamicFieldGet(
            ID => $ItemID,
        );
        push @Data, $DynamicField;
    }

    if (@Data) {

        # set cache
        $Self->{CacheObject}->Set(
            Type  => 'DynamicField',
            Key   => $CacheKey,
            Value => \@Data,
            TTL   => $Self->{CacheTTL},
        );
    }
    return \@Data;
}

=begin Internal:

=cut

=item _DynamicFieldReorder()

re-order the list of fields.

    $Success = $DynamicFieldObject->_DynamicFieldReorder(
        ID         => 123,              # mandatory, the field ID that triggers the re-order
        Mode       => 'Add',            # || Update || Delete
        FieldOrder => 2,                # mandatory, the FieldOrder from the trigger field
    );

    $Success = $DynamicFieldObject->_DynamicFieldReorder(
        ID            => 123,           # mandatory, the field ID that triggers the re-order
        Mode          => 'Update',      # || Update || Delete
        FieldOrder    => 2,             # mandatory, the FieldOrder from the trigger field
        OldFieldOrder => 10,            # mandatory for Mode = 'Update', the FieldOrder before the
                                        # update
    );

=cut

sub _DynamicFieldReorder {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(ID FieldOrder Mode)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => 'Need $Needed!' );
            return;
        }
    }

    if ( $Param{Mode} eq 'Update' ) {

        # check needed stuff
        if ( !$Param{OldFieldOrder} ) {
            $Self->{LogObject}->Log( Priority => 'error', Message => 'Need OldFieldOrder!' );
            return;
        }
    }

    # get the Dynamic Field trigger
    my $DynamicFieldTrigger = $Self->DynamicFieldGet(
        ID => $Param{ID},
    );

    # extract the field order form the params
    my $TriggerFieldOrder = $Param{FieldOrder};

    # get all fields
    my $DynamicFieldList = $Self->DynamicFieldListGet(
        Valid => 0,
    );

    # to store the fields that need to be updated
    my @NeedToUpdateList;

    # to add or subtract the field order by 1
    my $Substract;

    # update and add has different algorithms to select the fields to be updated
    # check if update
    if ( $Param{Mode} eq 'Update' ) {
        my $OldFieldOrder = $Param{OldFieldOrder};

        # if the new order and the old order are equal no operation should be performed
        # this is a double check from DynamicFieldUpdate (is case of the function is called
        # from outside)
        return if $TriggerFieldOrder eq $OldFieldOrder;

        # set subtract mode for selected fields
        if ( $TriggerFieldOrder gt $OldFieldOrder ) {
            $Substract = 1;
        }

        # identify fields that needs to be updated
        DYNAMICFIELD:
        for my $DynamicField ( @{$DynamicFieldList} ) {

            # skip wrong fields (if any)
            next DYNAMICFIELD if !IsHashRefWithData($DynamicField);

            my $CurrentOrder = $DynamicField->{FieldOrder};

            # skip fields with lower order number
            next DYNAMICFIELD
                if $CurrentOrder < $OldFieldOrder && $CurrentOrder < $TriggerFieldOrder;

            # skip trigger field
            next DYNAMICFIELD
                if ( $CurrentOrder eq $TriggerFieldOrder && $DynamicField->{ID} eq $Param{ID} );

            # skip this and the rest if has greater order number
            last DYNAMICFIELD
                if $CurrentOrder > $OldFieldOrder && $CurrentOrder > $TriggerFieldOrder;

            push @NeedToUpdateList, $DynamicField;
        }
    }

    # check if delete action
    elsif ( $Param{Mode} eq 'Delete' ) {

        $Substract = 1;

        # identify fields that needs to be updated
        DYNAMICFIELD:
        for my $DynamicField ( @{$DynamicFieldList} ) {

            # skip wrong fields (if any)
            next DYNAMICFIELD if !IsHashRefWithData($DynamicField);

            my $CurrentOrder = $DynamicField->{FieldOrder};

            # skip fields with lower order number
            next DYNAMICFIELD
                if $CurrentOrder < $TriggerFieldOrder;

            # skip trigger field
            next DYNAMICFIELD
                if ( $CurrentOrder eq $TriggerFieldOrder && $DynamicField->{ID} eq $Param{ID} );

            push @NeedToUpdateList, $DynamicField;
        }
    }

    # otherwise is add action
    else {

        # identify fields that needs to be updated
        DYNAMICFIELD:
        for my $DynamicField ( @{$DynamicFieldList} ) {

            # skip wrong fields (if any)
            next DYNAMICFIELD if !IsHashRefWithData($DynamicField);

            my $CurrentOrder = $DynamicField->{FieldOrder};

            # skip fields with lower order number
            next DYNAMICFIELD
                if $CurrentOrder < $TriggerFieldOrder;

            # skip trigger field
            next DYNAMICFIELD
                if ( $CurrentOrder eq $TriggerFieldOrder && $DynamicField->{ID} eq $Param{ID} );

            push @NeedToUpdateList, $DynamicField;
        }
    }

    # update the fields order incrementing or decrementing by 1
    for my $DynamicField (@NeedToUpdateList) {

        # hash ref validation is not needed since it was validated before
        # check if need to add or subtract
        if ($Substract) {

            # subtract 1 to the dynamic field order value
            $DynamicField->{FieldOrder}--;
        }
        else {

            # add 1 to the dynamic field order value
            $DynamicField->{FieldOrder}++;
        }

        # update the database
        my $Success = $Self->DynamicFieldUpdate(
            %{$DynamicField},
            UserID  => 1,
            Reorder => 0,
        );

        # check if the update was successful
        if ( !$Success ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => 'An error was detected while re ordering the field list on field '
                    . "DynamicField->{Name}!",
            );
            return;
        }
    }

    # delete cache
    $Self->{CacheObject}->CleanUp(
        Type => 'DynamicField',
    );

    return 1;
}
1;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut

=head1 VERSION

$Revision: 1.41 $ $Date: 2011-09-08 16:37:49 $

=cut
