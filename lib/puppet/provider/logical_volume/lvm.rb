Puppet::Type.type(:logical_volume).provide :lvm do
    desc "Manages LVM logical volumes"

    commands :lvcreate   => 'lvcreate',
             :lvremove   => 'lvremove',
             :lvextend   => 'lvextend',
             :lvs        => 'lvs',
             :resize2fs  => 'resize2fs',
             :umount     => 'umount',
             :blkid      => 'blkid',
             :dmsetup    => 'dmsetup'

    optional_commands :xfs_growfs => 'xfs_growfs',
                      :resize4fs  => 'resize4fs'

    def create
        args = ['-n', @resource[:name].split('/')[3]]
        if @resource[:size]
            args.push('--size', @resource[:size])
        elsif @resource[:initial_size]
            args.push('--size', @resource[:initial_size])
        end
        if @resource[:extents]
            args.push('--extents', @resource[:extents])
        end

        if !@resource[:extents] and !@resource[:size] and !@resource[:initial_size]
            args.push('--extents', '100%FREE')
        end

        if @resource[:stripes]
            args.push('--stripes', @resource[:stripes])
        end

        if @resource[:stripesize]
            args.push('--stripesize', @resource[:stripesize])
        end

        args << @resource[:name].split('/')[2]
        lvcreate(*args)
    end

    def destroy
        dmsetup('remove', "#{@resource[:name].split('/')[2]}-#{@resource[:name].split('/')[3]}")
        lvremove('-f', @resource[:name])
    end

    def exists?
        cmd = [command(:lvs), '--noheading', @resource[:name]]
        !execute(cmd, :failonfail => false, :combine => false).empty?
    end

    def self.instances
        inst = []
        cmd = [command(:lvs), '--noheading', '-o', 'vg_name,lv_name', '--separator', '/']
        lines = execute(cmd, :combine => false) 
        lines.inject([]) do |inst, name|
            inst << new(:name => "/dev/"+name.strip)
        end
        inst
    end

    def size
        if @resource[:size] =~ /^\d+\.?\d{0,2}([KMGTPE])/i
            unit = $1.downcase
        else
            unit = "m"
        end

        raw = lvs('--noheading', '--unit', unit, @resource[:name])

        if raw =~ /\s+(\d+)\.(\d+)#{unit}/i
            if $2.to_i == 00
                return $1 + unit.capitalize
            else
                return $1 + '.' + $2 + unit.capitalize
            end
        end
    end

    def size=(new_size)
        lvm_size_units = { "K" => 1, "M" => 1024, "G" => 1048576, "T" => 1073741824, "P" => 1099511627776, "E" => 1125899906842624 }
        lvm_size_units_match = lvm_size_units.keys().join('|')

        resizeable = false
        current_size = size()

        if current_size =~ /(\d+\.{0,1}\d{0,2})(#{lvm_size_units_match})/i
            current_size_bytes = $1.to_i
            current_size_unit  = $2.upcase
        end

        if new_size =~ /(\d+)(#{lvm_size_units_match})/i
            new_size_bytes = $1.to_i
            new_size_unit  = $2.upcase
        end

        ## Get the extend size
        if lvs('--noheading', '-o', 'vg_extent_size', '--units', 'k', @resource[:name]) =~ /\s+(\d+)\.\d+k/i
            vg_extent_size = $1.to_i
        end

        ## Verify that it's a extension: Reduce is potentially dangerous and should be done manually
        if lvm_size_units[current_size_unit] < lvm_size_units[new_size_unit]
            resizeable = true
        elsif lvm_size_units[current_size_unit] > lvm_size_units[new_size_unit]
            if (current_size_bytes * lvm_size_units[current_size_unit]) < (new_size_bytes * lvm_size_units[new_size_unit])
                resizeable = true
            end
        elsif lvm_size_units[current_size_unit] == lvm_size_units[new_size_unit]
            if new_size_bytes > current_size_bytes
                resizeable = true
            end
        end

        if not resizeable
            if @resource[:size_is_minsize] == :true or @resource[:size_is_minsize] == true or @resource[:size_is_minsize] == 'true'
                info( "Logical volume already has minimum size of #{new_size} (currently #{current_size})" )
            else
                fail( "Decreasing the size requires manual intervention (#{new_size} < #{current_size})" )
            end
        else
            ## Check if new size fits the extend blocks
            if new_size_bytes * lvm_size_units[new_size_unit] % vg_extent_size != 0
                fail( "Cannot extend to size #{new_size} because VG extent size is #{vg_extent_size} KB" )
            end

            lvextend( '-L', new_size, @resource[:name]) || fail( "Cannot extend to size #{new_size} because lvextend failed." )

            blkid_type = blkid(@resource[:name])
            if command(:resize4fs) and blkid_type =~ /\bTYPE=\"(ext4)\"/
              resize4fs( @resource[:name]) || fail( "Cannot resize file system to size #{new_size} because resize2fs failed." )
            elsif blkid_type =~ /\bTYPE=\"(ext[34])\"/
              resize2fs( @resource[:name]) || fail( "Cannot resize file system to size #{new_size} because resize2fs failed." )
            elsif blkid_type =~ /\bTYPE=\"(xfs)\"/
              xfs_growfs( @resource[:name]) || fail( "Cannot resize filesystem to size #{new_size} because xfs_growfs failed." )
            end

        end
    end
end
